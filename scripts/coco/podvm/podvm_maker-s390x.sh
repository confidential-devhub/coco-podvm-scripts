#!/bin/bash
# s390x variant of podvm_maker.sh
# Runs inside the guest via virt-customize (called by coco-components-s390x.sh).
#
# Differences from x86_64:
#   - CentOS mirror uses s390x path instead of x86_64
#   - Serial console unit is ttysclp0 (s390x line-mode console), not ttyS0
#   - e2fsprogs may already be installed (base image has it);
#     use an idempotent install
set -ex

# e2fsprogs is in RHSM repos.
# If ACTIVATION_KEY + ORG_ID are exported (from coco-components-s390x.sh),
# the image is already registered; otherwise fall back to the CentOS mirror.
if subscription-manager identity &>/dev/null; then
    dnf install -y e2fsprogs || true
else
    dnf config-manager \
        --add-repo=https://mirror.stream.centos.org/10-stream/AppStream/s390x/os/
    dnf install -y --nogpgcheck e2fsprogs || true
    dnf clean all
    dnf config-manager --set-disabled "*centos*"
fi

# jq is needed in the guest by create-scratch-s390x.sh.  It was not found in the
# CentOS 10-stream mirror, so a repo install is only tried opportunistically
# (RHSM-registered case); otherwise fall back to the official static s390x
# binary from GitHub, which needs outbound access to github.com.
if ! command -v jq &>/dev/null; then
    dnf install -y jq || true
fi
if ! command -v jq &>/dev/null; then
    curl -fsSLo /usr/bin/jq \
        https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-s390x
    chmod +x /usr/bin/jq
fi
jq --version

# Extract CoCo payload tarballs
tar -xzvf /tmp/podvm-binaries.tar.gz -C /
tar -xzvf /tmp/pause-bundle.tar.gz -C /
tar -xzvf /tmp/luks-config.tar.gz -C /

# Fix 2: service file permissions
# build.sh creates luks-config.tar.gz from the host source tree which may carry
# executable or world-writable bits (macOS umask / extended attributes).
# systemd refuses to load service units with those bits set, so normalise them here.
chmod 644 /etc/systemd/system/luks-scratch.service
chmod 644 /etc/systemd/system/kata-agent.service.d/10-override.conf

# Remove cloud-init — kata-agent takes over from this point
dnf remove -y cloud-init || true

# Fix podns@netns service — SELinux label for /usr/bin/ip
semanage fcontext -a -t bin_t /usr/bin/ip && restorecon -v /usr/sbin/ip

# Enable the LUKS scratch partition service
systemctl enable /etc/systemd/system/luks-scratch.service

# s390x-specific fix: systemd-repart disk discovery fails at runtime on s390x.
#
# create-scratch.sh calls:
#   systemd-repart --dry-run=no --definitions=<scratch.conf> ...
# without specifying which disk to operate on.  systemd-repart auto-discovers
# the disk by walking /proc/self/mountinfo from the current root:
#   overlayfs → dm-verity (/dev/mapper/root) → vda2 → vda
# On x86 the chain goes through dm-crypt which correctly exposes its backing
# block device in sysfs.  On s390x, dm-verity does not expose the backing
# block device in a way systemd-repart can traverse, so it returns an empty
# JSON array.  create-scratch.sh then extracts null and calls:
#   cryptsetup luksOpen null scratch  →  fails immediately
#
# Fix: install a drop-in that overrides ExecStart to call a thin wrapper.
# The wrapper determines the real virtio disk (/dev/vda) and passes it
# explicitly as the first argument to systemd-repart, bypassing auto-discovery.
mkdir -p /etc/systemd/system/luks-scratch.service.d

cat > /usr/local/sbin/create-scratch-s390x.sh << 'EOSCRIPT'
#!/bin/bash
# s390x wrapper for luks-scratch.
# systemd-repart cannot auto-discover the disk through the dm-verity chain.
# Determine the real block device under / and pass it explicitly.
#
# Flow:
#   1. Find the disk backing /dev/mapper/root via sysfs dm slaves.
#   2. Run systemd-repart to create + encrypt + format the scratch partition.
#   3. If systemd-repart returns activity==unchanged (partition already exists
#      with the right GPT type but was never LUKS-formatted — e.g. created by
#      qemu-img resize at a prior step), fall back to direct cryptsetup +
#      mkfs.ext4 to complete the setup.
#   4. Open the LUKS device as /dev/mapper/scratch.
set -e

SCRATCH_TYPE=773f91ef-66d4-49b5-bd83-d683bf40ad16
KEY_PATH=/run/lukspw.bin
WORKDIR=$(mktemp -d)

dd if=/dev/urandom of="$KEY_PATH" bs=64 count=1 2>/dev/null
chmod 600 "$KEY_PATH"

cat > "$WORKDIR/scratch.conf" << 'EOF'
[Partition]
# Use user-home GUID (773f91ef) — absent from a fresh disk so systemd-repart
# always creates a new partition.  If the partition already exists with this
# type but is not yet LUKS-formatted, the fallback path below handles it.
Type=773f91ef-66d4-49b5-bd83-d683bf40ad16
Label=scratch
Encrypt=key-file
Format=ext4
EOF

# Find the real virtio disk backing /dev/mapper/root.
# /dev/mapper/root → dm-0 → /sys/block/dm-0/slaves/ → e.g. vda2 → disk vda.
ROOT_MAP=$(readlink -f /dev/mapper/root 2>/dev/null || echo "/dev/dm-0")
DM_NAME=$(basename "$ROOT_MAP")
SLAVE=$(ls /sys/block/"$DM_NAME"/slaves/ 2>/dev/null | head -1)
if [[ -n "$SLAVE" ]]; then
    DISK_NAME=$(echo "$SLAVE" | sed 's/[0-9]*$//')
    DISK="/dev/$DISK_NAME"
else
    DISK=$(ls /dev/vd? 2>/dev/null | head -1)
fi

echo "s390x create-scratch: using disk $DISK"

out=$(systemd-repart "$DISK" \
    --dry-run=no \
    --key-file="$KEY_PATH" \
    --definitions="$WORKDIR" \
    --no-pager \
    --json=pretty)

echo "$out"

sda=$(echo "$out" | jq -r '.[] | select(.activity=="create") | .node')

if [[ -z "$sda" ]]; then
    # systemd-repart returned unchanged — partition already exists in the GPT
    # with the right type but may not be LUKS-formatted yet (e.g. the partition
    # was pre-created by qemu-img resize without LUKS setup).
    echo "systemd-repart: no partition created (activity==unchanged)."
    echo "Checking for existing unformatted scratch partition ..."

    # Find the partition on DISK with the scratch type GUID.
    sda=$(lsblk -o NAME,PARTTYPE -r "$DISK" \
        | grep -i "$SCRATCH_TYPE" \
        | awk '{print "/dev/"$1}' | head -1)

    if [[ -z "$sda" ]]; then
        echo "ERROR: no partition with type $SCRATCH_TYPE found on $DISK" >&2
        exit 1
    fi

    echo "Found scratch partition: $sda"

    if cryptsetup isLuks "$sda" 2>/dev/null; then
        echo "Partition is already LUKS-formatted — opening directly."
    else
        echo "Partition not LUKS-formatted — running luksFormat + mkfs.ext4 ..."
        cryptsetup luksFormat "$sda" --key-file "$KEY_PATH" --batch-mode
        cryptsetup luksOpen  "$sda" scratch --key-file "$KEY_PATH"
        mkfs.ext4 /dev/mapper/scratch
        cryptsetup luksClose scratch
        echo "LUKS format + ext4 complete."
    fi
fi

echo "Opening LUKS device $sda as /dev/mapper/scratch ..."
cryptsetup luksOpen "$sda" scratch --key-file "$KEY_PATH"

rm -rf "$WORKDIR"
echo "Process completed."
EOSCRIPT

chmod +x /usr/local/sbin/create-scratch-s390x.sh

# Override ExecStart in the service unit to use the s390x wrapper
cat > /etc/systemd/system/luks-scratch.service.d/s390x-disk-discovery.conf << 'EOF'
[Service]
ExecStart=
ExecStart=/usr/local/sbin/create-scratch-s390x.sh
EOF

# Print vTPM PCR values to the serial console at boot
cat <<'SCRIPT' > /usr/libexec/gen-issue
#!/usr/bin/env bash
set -euo pipefail

if ! tpm2_pcrread sha256:0 > /dev/null 2>&1; then
   echo "No vTPM detected"
   exit 0
fi

mkdir -p /run/issue.d
rm -f /etc/issue.net
rm -f /etc/issue
{
  echo "Detected vTPM PCR values:"
  /usr/bin/tpm2_pcrread sha256:all
  echo
} > /run/issue.d/30-pcrs.issue
SCRIPT

mv /etc/issue.d /usr/lib/issue.d || true
rm -f /etc/issue.net
rm -f /etc/issue
chmod +x /usr/libexec/gen-issue

# s390x serial console unit is ttysclp0 (not ttyS0)
cat <<EOF > /etc/systemd/system/gen-issue.service
[Unit]
Description=Generate issue to print to serial console at startup
Before=serial-getty@ttysclp0.service
After=process-user-data.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/libexec/gen-issue

[Install]
WantedBy=multi-user.target
EOF
ln -sf ../gen-issue.service \
    /etc/systemd/system/multi-user.target.wants/gen-issue.service

# Extend PCR8 with the initdata digest after process-user-data runs
#
# The drop-in below mounts the CAA cidata ISO at /media/cidata. The RHEL 10
# s390x base image has no /media/cidata, and the '-' prefix on ExecStartPre hides
# the mount failure ("mount point does not exist"). process-user-data then finds
# no user-data, generates dummy initdata, and CDH/AA get an empty initdata.
mkdir -p /media/cidata
mkdir -p /etc/systemd/system/process-user-data.service.d/
cat <<'EOF' > /etc/systemd/system/process-user-data.service.d/10-override.conf
[Service]
ExecStartPre=-/bin/mount -t iso9660 -o ro /dev/disk/by-label/cidata /media/cidata
ExecStartPost=-/bin/bash -c 'tpm2_pcrextend 8:sha256=$(head -c64 /run/peerpod/initdata.digest)'
EOF

# Open firewall port required for CoCo networking
firewall-offline-cmd --zone=public --add-port=15150/tcp

# Fix 1: SELinux — /etc/ld.so.cache is unlabeled_t on the overlay upper layer
#
# When the image boots with systemd.volatile=overlay the root fs is an overlayfs
# whose upper layer (tmpfs) carries no SELinux labels.  /etc/ld.so.cache lands as
# unlabeled_t and SELinux (enforcing) denies { map } to every dynamically-linked
# process (all CoCo binaries: agent-protocol-forwarder, kata-agent,
# process-user-data, gen-issue, …).  The binaries never execute — they fail before
# the kernel ELF loader can enter user-space.
#
# Triggering a full relabel at first boot (/.autorelabel) causes the initrd to run
# fixfiles relabel on every file in the overlayfs upper layer before PID 1 starts,
# restoring correct labels (ld_so_cache_t for /etc/ld.so.cache).  The file is
# removed automatically after relabeling so subsequent boots are unaffected.
#
# We also run restorecon on /etc immediately (inside the chroot, where the
# filesystem is ext4 not overlay) so that the base labels are correct in the image
# before the overlay is ever mounted.
restorecon -r /etc
touch /.autorelabel
