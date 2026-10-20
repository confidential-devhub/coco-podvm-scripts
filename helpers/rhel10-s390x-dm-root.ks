# Kickstart for RHEL 10 s390x CoCo PodVM base image
# Use helpers/build-s390x-base-image.sh to run virt-install with this file.
# That script passes ORG_ID and ACTIVATION_KEY as kernel cmdline parameters
# (inst.ks.org_id= and inst.ks.activation_key=) so %post can register RHSM
# without any manual intervention.
#version=RHEL10
text

# No explicit repo directive: Anaconda automatically exposes both BaseOS and
# AppStream from the mounted ISO when inst.repo=hd:LABEL=<iso label>:/ is on the cmdline.
# An explicit repo --baseurl= line is only needed for supplementary repos.

%addon com_redhat_kdump --disable
%end

keyboard --vckeymap=us --xlayouts='us'
lang en_US.UTF-8
network --bootproto=dhcp --hostname=localhost.localdomain
firewall --disabled
# No install-source directive: the source is set by inst.repo= on the kernel
# cmdline (see helpers/build-s390x-base-image.sh).

# Root password — cleared by waagent deprovision at end of %post
rootpw --allow-ssh redhat123

selinux --enforcing

# Only enable services that exist on the minimal install from DVD.
# WALinuxAgent and cloud services are enabled after dnf install in %post.
services --enabled="sshd,NetworkManager"

timezone Etc/UTC --utc
skipx

# Power off automatically when %post completes — no manual intervention needed
poweroff

%packages
@^minimal-environment
openssh-server
kernel
redhat-release

-*gpu-firmware*
-linux-firmware*
-iwl*

# Available on DVD:
tpm2-tools
cryptsetup
cloud-init
e2fsprogs

# NOT on DVD — installed in %post via RHSM after subscription-manager register:
#   WALinuxAgent, cloud-utils-growpart, NetworkManager-cloud-setup,
#   kernel-modules-extra, afterburn, python3-dnf-plugin-versionlock

%end

firstboot --disable

# ── Target disk selection ─────────────────────────────────────────────────────
# The installer VM has two virtio-blk disks: the blank target qcow2 and the
# read-only install ISO.  The guest kernel names them vda/vdb in virtio probe
# order, which is NOT stable between boots (Bug 17), so the target disk must not
# be hard-coded.  %pre picks the writable, non-ISO9660 disk and generates the
# partitioning commands into /tmp/part-include.
%pre --erroronfail
#!/bin/bash
set -eu
TARGET=""
for d in /sys/block/vd*; do
    [ -e "$d" ] || continue
    name="${d##*/}"
    # The install ISO is attached readonly=on -> /sys/block/<dev>/ro == 1
    [ "$(cat "$d/ro")" = "0" ] || continue
    # Belt and braces: never touch a disk that carries an ISO 9660 filesystem
    [ "$(blkid -p -s TYPE -o value "/dev/$name" 2>/dev/null || true)" != "iso9660" ] || continue
    if [ -n "$TARGET" ]; then
        echo "ERROR: more than one writable virtio disk found ($TARGET, $name)" >&2
        exit 1
    fi
    TARGET="$name"
done
if [ -z "$TARGET" ]; then
    echo "ERROR: no writable virtio target disk found" >&2
    exit 1
fi
echo "Kickstart target disk: $TARGET"
echo "$TARGET" > /tmp/target-disk

# Partition layout:
#   <disk>1  128 MiB /boot-se ext4 — holds the Secure Execution .protvirt image for
#                                 --write-to-disk all-in-one SE qcow2 (Bug 19). A plain
#                                 partition has no Anaconda/blivet PReP 4-10 MiB cap.
#   <disk>2  rest    ext4 root  — typed with s390x DPS GUID in %post
cat > /tmp/part-include <<EOF
ignoredisk --only-use=${TARGET}
clearpart --none --initlabel
part /boot-se --fstype="ext4"     --ondisk=${TARGET} --size=128
part /        --fstype="ext4"     --ondisk=${TARGET} --grow
EOF
%end

%include /tmp/part-include

# Hand the target disk name from the installer environment to the chrooted %post.
%post --nochroot --erroronfail
mkdir -p /mnt/sysroot/tmp
cp /tmp/target-disk /mnt/sysroot/tmp/target-disk
%end

%post --erroronfail
set -ex

# ── 1. Fix root partition GUID ────────────────────────────────────────────────
# systemd-repart identifies the root partition by its GPT type UUID.
# Anaconda sets a generic Linux data GUID; overwrite with the s390x-specific
# Discoverable Partitions Spec value so verity-s390x.sh can find it later.
TARGET_DISK=$(cat /tmp/target-disk)
sfdisk --part-type "/dev/${TARGET_DISK}" 2 08A7ACEA-624C-4A20-91E8-6E0FA67D23F9
rm -f /tmp/target-disk

# ── 2. Register with RHSM using credentials passed on the kernel cmdline ──────
# helpers/build-s390x-base-image.sh appends:
#   inst.ks.org_id=<ORG_ID> inst.ks.activation_key=<KEY>
# to the virt-install --extra-args so Anaconda makes them available here.
ORG_ID=$(sed -n 's/.*inst\.ks\.org_id=\([^ ]*\).*/\1/p' /proc/cmdline)
ACTIVATION_KEY=$(sed -n 's/.*inst\.ks\.activation_key=\([^ ]*\).*/\1/p' /proc/cmdline)

if [[ -n "$ORG_ID" && -n "$ACTIVATION_KEY" ]]; then
    subscription-manager register \
        --org="$ORG_ID" \
        --activationkey="$ACTIVATION_KEY"
else
    echo "WARNING: ORG_ID or ACTIVATION_KEY not found on cmdline." >&2
    echo "         Network packages will not be installed."          >&2
    echo "         Pass them via build-s390x-base-image.sh."        >&2
fi

# ── 3. Install packages not available on the DVD ──────────────────────────────
# Only run if we are registered (subscription-manager identity succeeds).
if subscription-manager identity &>/dev/null; then
    dnf install -y \
        WALinuxAgent \
        cloud-utils-growpart \
        NetworkManager-cloud-setup \
        kernel-modules-extra \
        afterburn \
        python3-dnf-plugin-versionlock
    dnf clean all

    # Enable the services that were installed post-DVD
    systemctl enable waagent \
        nm-cloud-setup.service nm-cloud-setup.timer \
        cloud-init cloud-init-local cloud-config cloud-final

    # Unregister — the installed image should not carry active entitlements
    subscription-manager unregister || true
    subscription-manager clean        || true
fi

# ── 4. Kernel install hooks ───────────────────────────────────────────────────
# Disable grub and rescue dracut hooks so future kernel-install runs are fast
# and don't try to build a GRUB config (there is no GRUB on s390x here).
mkdir -p /etc/kernel/install.d
touch /etc/kernel/install.d/20-grub.install
touch /etc/kernel/install.d/50-dracut.install

# ── 5. Lock the bootloader ────────────────────────────────────────────────────
dnf versionlock add s390utils-base 2>/dev/null || true

# ── 6. Deprovision ───────────────────────────────────────────────────────────
# Clears SSH host keys, DHCP leases, cloud-init state so the image is clean.
/usr/sbin/waagent -force -deprovision || true

# ── 7. Reclaim unused blocks ──────────────────────────────────────────────────
fstrim -v / ||:

%end
