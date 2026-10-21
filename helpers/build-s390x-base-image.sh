#!/bin/bash
set -e

# Fully automated wrapper around virt-install to build the RHEL 10 s390x
# CoCo PodVM base image using helpers/rhel10-s390x-dm-root.ks.
#
# Handles everything that required manual intervention during development:
#   - Passes ORG_ID + ACTIVATION_KEY into the kickstart %post via kernel cmdline
#   - Uses --noautoconsole --wait -1 so virt-install blocks until the VM
#     powers off (kickstart ends with `poweroff`) — no TTY warning, no hanging
#   - Destroys and undefines the transient domain on completion or error
#   - Writes the output disk to OUTPUT_DIR/rhel10-s390x-base.qcow2
#
# Cross-architecture (x86 host) support:
#   On an s390x KVM host the script uses --virt-type kvm for hardware acceleration.
#   On any other host (e.g. x86_64) it automatically falls back to pure software
#   emulation via --virt-type qemu --emulator qemu-system-s390x.
#   The build is architecturally identical in both modes; only speed differs:
#     s390x KVM  : ~15 minutes
#     x86 QEMU   : ~1–3 hours (TCG software emulation, no KVM acceleration)
#   See docs/s390x-build-on-x86/README.md for the full cross-build guide.

SCRIPT_DIR=$(dirname "$(realpath "$0")")
REPO_ROOT=$(realpath "$SCRIPT_DIR/..")

function usage()
{
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Build the RHEL 10 s390x CoCo PodVM base image unattended."
    echo ""
    echo "Options (env vars or flags):"
    echo "  ORG_ID           mandatory  RHSM organisation ID"
    echo "  ACTIVATION_KEY   mandatory  RHSM activation key"
    echo "  ISO_PATH         optional   path to RHEL 10 s390x DVD ISO"
    echo "                              Default: \$REPO_ROOT/RHEL-10.2-s390x-dvd1.iso"
    echo "  OUTPUT_DIR       optional   directory for the output qcow2"
    echo "                              Default: \$REPO_ROOT/../output"
    echo "  OUTPUT_NAME      optional   output filename (no path)"
    echo "                              Default: rhel10-s390x-base.qcow2"
    echo "  DISK_SIZE_GB     optional   disk size in GiB. Default: 7"
    echo "  VM_MEMORY_MB     optional   installer VM RAM in MiB. Default: 8192"
    echo "  VM_NAME          optional   transient VM name. Default: rhel10-s390x-build-\$\$"
    echo ""
    echo "Cross-architecture:"
    echo "  On s390x the installer VM uses KVM (hardware acceleration, ~15 min)."
    echo "  On x86_64 or any non-s390x host the script automatically uses"
    echo "  qemu-system-s390x software emulation (~1-3 hours)."
    echo "  Requires: qemu-system-s390x installed on the x86 host."
    echo ""
    echo "Example:"
    echo "  ORG_ID=<YOUR_ORG_ID> ACTIVATION_KEY=<YOUR_ACTIVATION_KEY> $0"
}

if [[ "${1:-}" == "help" || "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

# ── Validate mandatory inputs ─────────────────────────────────────────────────
if [[ -z "${ORG_ID:-}" ]]; then
    echo "ERROR: ORG_ID is required." >&2
    usage; exit 1
fi
if [[ -z "${ACTIVATION_KEY:-}" ]]; then
    echo "ERROR: ACTIVATION_KEY is required." >&2
    usage; exit 1
fi

# ── Defaults ──────────────────────────────────────────────────────────────────
ISO_PATH=${ISO_PATH:-"$REPO_ROOT/RHEL-10.2-s390x-dvd1.iso"}
OUTPUT_DIR=${OUTPUT_DIR:-"$REPO_ROOT/../output"}
OUTPUT_NAME=${OUTPUT_NAME:-"rhel10-s390x-base.qcow2"}
DISK_SIZE_GB=${DISK_SIZE_GB:-7}
VM_MEMORY_MB=${VM_MEMORY_MB:-8192}
VM_NAME=${VM_NAME:-"rhel10-s390x-build-$$"}
KS_FILE="$SCRIPT_DIR/rhel10-s390x-dm-root.ks"
OUTPUT_DISK="$OUTPUT_DIR/$OUTPUT_NAME"

# ── Pre-flight checks ─────────────────────────────────────────────────────────
echo ""
echo "=== s390x base image build ==="
echo "ISO_PATH:    $ISO_PATH"
echo "OUTPUT_DISK: $OUTPUT_DISK"
echo "KS_FILE:     $KS_FILE"
echo "VM_NAME:     $VM_NAME"
echo "DISK_SIZE:   ${DISK_SIZE_GB} GiB"
echo "RAM:         ${VM_MEMORY_MB} MiB"
echo ""

if [[ ! -f "$ISO_PATH" ]]; then
    echo "ERROR: ISO not found at $ISO_PATH" >&2
    exit 1
fi

if [[ ! -f "$KS_FILE" ]]; then
    echo "ERROR: Kickstart not found at $KS_FILE" >&2
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

# Remove leftover disk from a previous failed attempt
rm -f "$OUTPUT_DISK"

# ── Expose ISO to virt-install via loop mount ─────────────────────────────────
# virt-install --location requires a directory (install tree root).
# We use an explicit losetup -f to find a free loop device and mount read-only.
#
# The ISO also needs to be attached as a second virtio disk so the guest can
# reach images/install.img (the stage2 squashfs).  QEMU runs as uid:107
# (qemu user) and cannot access paths under /root — copy the ISO into
# /var/lib/libvirt/images/ which is already qemu-accessible.
# We bind-mount (read-only) to avoid duplicating 8 GB on disk.
ISO_LIBVIRT_LINK="/var/lib/libvirt/images/rhel10-s390x-install.iso"
if [[ ! -f "$ISO_LIBVIRT_LINK" ]]; then
    echo "Bind-mounting ISO for QEMU access ..."
    touch "$ISO_LIBVIRT_LINK"
    mount --bind "$ISO_PATH" "$ISO_LIBVIRT_LINK"
    echo "  → bind-mounted $ISO_PATH at $ISO_LIBVIRT_LINK"
fi

ISO_MOUNT=$(mktemp -d /tmp/rhel10-s390x-iso-mount.XXXXXX)
ISO_MOUNTED=0

echo "Mounting ISO ..."
modprobe loop 2>/dev/null || true
LODEV=$(losetup -f 2>/dev/null || true)
if [[ -z "$LODEV" ]]; then
    echo "ERROR: No free loop device available." >&2
    echo "  Check: losetup -a" >&2
    rm -rf "$ISO_MOUNT"; exit 1
fi
losetup -r "$LODEV" "$ISO_PATH"
if mount -o ro "$LODEV" "$ISO_MOUNT"; then
    echo "  → loop-mounted $ISO_PATH at $ISO_MOUNT (via $LODEV)"
    ISO_MOUNTED=1
    LOCATION="$ISO_MOUNT"
else
    losetup -d "$LODEV" 2>/dev/null || true
    echo "ERROR: Failed to mount ISO at $ISO_PATH" >&2
    rm -rf "$ISO_MOUNT"; exit 1
fi

# ── Cleanup handler ───────────────────────────────────────────────────────────
function cleanup()
{
    local rc=$?
    echo ""
    # Destroy the VM if it is still running (e.g. on Ctrl-C or error)
    if virsh domstate "$VM_NAME" &>/dev/null; then
        echo "Destroying transient VM $VM_NAME ..."
        virsh destroy "$VM_NAME" 2>/dev/null || true
    fi
    # Unmount and detach loop device for the install tree temp dir
    if [[ "$ISO_MOUNTED" -eq 1 ]] && mountpoint -q "$ISO_MOUNT" 2>/dev/null; then
        echo "Unmounting ISO at $ISO_MOUNT ..."
        umount "$ISO_MOUNT" 2>/dev/null || true
        [[ -n "${LODEV:-}" ]] && losetup -d "$LODEV" 2>/dev/null || true
    fi
    [[ -n "$ISO_MOUNT" ]] && rm -rf "$ISO_MOUNT"
    if mountpoint -q "$ISO_LIBVIRT_LINK" 2>/dev/null; then
        umount "$ISO_LIBVIRT_LINK" 2>/dev/null || true
    fi
    rm -f "$ISO_LIBVIRT_LINK"
    if [[ $rc -ne 0 ]]; then
        echo "Build FAILED (exit code $rc)." >&2
    fi
    exit $rc
}
trap cleanup EXIT SIGINT SIGTERM

# ── Identify the installer repo by ISO volume label ───────────────────────────
# Do NOT name the ISO disk by kernel device (/dev/vdb): the guest assigns vdX
# in virtio-blk probe order, which is not stable between boots.  When the order
# flips, inst.repo=hd:/dev/vdb: points at the blank target disk and dracut
# loops forever ("Can't find a SQUASHFS superblock on vdb").  The ISO volume
# label is read from the loop device already attached above.
ISO_LABEL=$(blkid -s LABEL -o value "$LODEV" 2>/dev/null || true)
if [[ -z "$ISO_LABEL" ]]; then
    echo "ERROR: could not read ISO volume label from $LODEV ($ISO_PATH)." >&2
    echo "  Check: blkid $LODEV" >&2
    exit 1
fi
echo "ISO volume label: $ISO_LABEL"

# ── Detect host architecture and select virtualisation type ──────────────────
# On a native s390x KVM host, use hardware-accelerated KVM.
# On any other host (x86_64, aarch64, etc.) fall back to software emulation via
# qemu-system-s390x.  The two paths produce bit-identical qcow2 output; only
# build time differs (~15 min KVM vs ~1-3 h QEMU TCG on x86).
HOST_ARCH=$(uname -m)
if [[ "$HOST_ARCH" == "s390x" ]]; then
    VIRT_TYPE="kvm"
    VIRT_TYPE_ARGS=(--virt-type kvm)
    echo "Host arch: s390x — using KVM hardware acceleration"
else
    # libvirt's QEMU driver probes /usr/bin/qemu-system-* at startup to build
    # its capabilities XML.  It caches capabilities keyed by the EXACT binary
    # path it probed — typically the symlink path /usr/bin/qemu-system-s390x.
    #
    # If command -v resolves to /usr/local/bin/qemu-system-s390x (the symlink
    # target) instead, virt-install passes that path to libvirt, which finds no
    # capabilities entry for it and rejects with:
    #   "Host does not support any virtualization options for architecture 's390x'"
    #
    # Fix: always prefer /usr/bin/qemu-system-s390x (the path libvirt probed).
    # Fall back to command -v only if /usr/bin/ does not have it.
    if [[ -x /usr/bin/qemu-system-s390x ]]; then
        QEMU_S390X=/usr/bin/qemu-system-s390x
    else
        QEMU_S390X=$(command -v qemu-system-s390x 2>/dev/null || true)
    fi
    if [[ -z "$QEMU_S390X" ]]; then
        echo "ERROR: qemu-system-s390x not found on PATH or at /usr/bin/qemu-system-s390x." >&2
        echo "  Install it first:" >&2
        echo "    Fedora/RHEL: sudo dnf install qemu-system-s390x" >&2
        echo "    Ubuntu:      sudo apt install qemu-system-misc" >&2
        echo "  See docs/s390x-build-on-x86/README.md for the full guide." >&2
        exit 1
    fi
    VIRT_TYPE="qemu"
    VIRT_TYPE_ARGS=(--virt-type qemu --boot "emulator=${QEMU_S390X}")
    echo "Host arch: $HOST_ARCH — using QEMU software emulation ($QEMU_S390X)"
    echo "NOTE: Software emulation is ~5-10x slower than native KVM."
    echo "      Expected build time: 1-3 hours. Output is identical to KVM."
fi

# ── Run virt-install ──────────────────────────────────────────────────────────
# Key flags:
#   --noautoconsole   suppress the "no TTY" warning; do not try to open console
#   --wait -1         block until the domain shuts off (poweroff in kickstart)
#   --transient       domain is automatically undefined when it shuts off
#
# ORG_ID and ACTIVATION_KEY are passed as custom kernel cmdline parameters
# inst.ks.org_id= and inst.ks.activation_key= — Anaconda preserves all
# inst.ks.* parameters and makes the full cmdline available in /proc/cmdline
# inside the %post environment so the kickstart can read them with sed.
#
# The ISO is attached to the guest as a second virtio-blk disk (guest name not fixed):
#   - virt-install --location only extracts kernel+initrd and injects no
#     inst.repo/inst.stage2; the stage2 squashfs (images/install.img) lives
#     on the ISO and must be reachable by the guest at boot time.
#   - inst.repo=hd:LABEL=<iso label>:/ names the ISO by volume label.  A bare
#     inst.repo=cdrom/hd: leaves "root" unset in dracut's
#     27-parse-anaconda-repo.sh and falls back to polling /sys/block/sr*,
#     which a virtio-blk disk never matches.  A kernel device name such as
#     /dev/vdb must NOT be used: vda/vdb are assigned in probe order and can
#     swap between boots (Bug 17).
# The loop mount ($LOCATION) is still used so virt-install can extract
# kernel.img + initrd.img.

virt-install \
    "${VIRT_TYPE_ARGS[@]}" \
    --osinfo detect=on,require=off \
    --arch s390x \
    --name "$VM_NAME" \
    --memory "$VM_MEMORY_MB" \
    --location "$LOCATION" \
    --disk "path=${OUTPUT_DISK},format=qcow2,bus=virtio,size=${DISK_SIZE_GB}" \
    --disk "path=${ISO_LIBVIRT_LINK},device=disk,format=raw,bus=virtio,readonly=on" \
    --initrd-inject "$KS_FILE" \
    --nographics \
    --noautoconsole \
    --wait -1 \
    --extra-args "console=ttysclp0 inst.repo=hd:LABEL=${ISO_LABEL}:/ inst.ks=file:/rhel10-s390x-dm-root.ks inst.ks.org_id=${ORG_ID} inst.ks.activation_key=${ACTIVATION_KEY}" \
    --transient

echo ""
echo "=== Build complete ==="
echo "Output: $OUTPUT_DISK"
ls -lh "$OUTPUT_DISK"
