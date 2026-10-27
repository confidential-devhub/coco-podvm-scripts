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

# ── Loop-mount the ISO to read kernel/initrd (x86 direct-QEMU path) ──────────
# On the x86 path, we call qemu-system-s390x directly (no libvirt).  Direct
# QEMU can read the ISO file directly as a drive — no bind-mount into
# /var/lib/libvirt/images/ is needed (that was only required so libvirt's
# 'qemu' user could access the file).
#
# We still loop-mount the ISO to extract kernel.img + initrd.img from it.
# The loop mount is read-only and temporary.
#
# On the native s390x KVM path, virt-install --location needs the mounted
# directory as its --location argument, so ISO_MOUNT is used there too.
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
    # On s390x KVM path, destroy the VM if still running
    if command -v virsh &>/dev/null && virsh domstate "$VM_NAME" &>/dev/null; then
        echo "Destroying transient VM $VM_NAME ..."
        virsh destroy "$VM_NAME" 2>/dev/null || true
    fi
    # Clean up the ISO bind-mount sentinel and mount point if they exist.
    # This must run on both success and failure so a failed build does not leave
    # a stale sentinel file that silently skips the bind-mount on the next run.
    if [[ -n "${ISO_LIBVIRT_LINK:-}" ]]; then
        mountpoint -q "$ISO_LIBVIRT_LINK" 2>/dev/null && umount "$ISO_LIBVIRT_LINK" || true
        rm -f "$ISO_LIBVIRT_LINK"
    fi
    # Unmount and detach loop device
    if [[ "$ISO_MOUNTED" -eq 1 ]] && mountpoint -q "$ISO_MOUNT" 2>/dev/null; then
        echo "Unmounting ISO at $ISO_MOUNT ..."
        umount "$ISO_MOUNT" 2>/dev/null || true
        [[ -n "${LODEV:-}" ]] && losetup -d "$LODEV" 2>/dev/null || true
    fi
    [[ -n "$ISO_MOUNT" ]] && rm -rf "$ISO_MOUNT"
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

# ── Detect host architecture and select QEMU binary ─────────────────────────
# On a native s390x KVM host, use hardware-accelerated KVM via virt-install.
# On any other host (x86_64 inside a container), call qemu-system-s390x
# DIRECTLY — bypassing libvirt entirely.
#
# WHY direct QEMU instead of virt-install on x86:
#   virt-install is a frontend for libvirtd/virtqemud.  Inside a Podman
#   container the daemon cannot reliably probe cross-arch emulators regardless
#   of symlink placement or base image:
#     - UBI9 (glibc 2.34): Fedora 40 qemu-system-s390x requires GLIBC_2.38 →
#       capability probe segfaults → libvirt records no s390x capabilities.
#     - Fedora 40 base: virtqemud starts fine but the TCG capability probe
#       (-machine none,accel=tcg) fails inside a container namespace because
#       /dev/kvm is absent and seccomp/cgroup restrictions block fork+exec.
#   Direct QEMU bypasses ALL libvirt machinery: no daemon, no capability XML,
#   no domain definition — just exec qemu-system-s390x with the right flags.
#
# The direct QEMU command replicates exactly what virt-install --location does
# internally:
#   1. Extract kernel.img + initrd.img from the ISO images/ directory.
#   2. Append the kickstart file to the initrd cpio archive.
#   3. Boot with -kernel/-initrd/-append, two virtio-blk drives (output disk
#      + ISO), and enough RAM to run Anaconda.
HOST_ARCH=$(uname -m)
if [[ "$HOST_ARCH" == "s390x" ]]; then
    # Native s390x — use hardware KVM via virt-install (unchanged path).
    echo "Host arch: s390x — using KVM hardware acceleration via virt-install."

    # On a native s390x KVM host, libvirt's qemu user needs the ISO in a
    # qemu-accessible path.  Bind-mount it under /var/lib/libvirt/images/.
    ISO_LIBVIRT_LINK="/var/lib/libvirt/images/rhel10-s390x-install.iso"
    # Use mountpoint -q to test whether the bind-mount is already active.
    # The old guard (`[[ ! -f ]]` on a sentinel file) was fragile: a failed
    # previous run left the empty file in place, causing the next run to skip
    # the mount and pass an empty file to virt-install as the install ISO.
    if ! mountpoint -q "$ISO_LIBVIRT_LINK" 2>/dev/null; then
        touch "$ISO_LIBVIRT_LINK"
        mount --bind "$ISO_PATH" "$ISO_LIBVIRT_LINK"
    fi

    virt-install \
        --virt-type kvm \
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

    # The cleanup trap handles ISO_LIBVIRT_LINK unmount + file removal on both
    # success and failure paths, so nothing more is needed here.

else
    # x86 cross-build — call qemu-system-s390x directly, no libvirt.
    QEMU_S390X=$(command -v qemu-system-s390x 2>/dev/null || true)
    if [[ -z "$QEMU_S390X" ]]; then
        echo "ERROR: qemu-system-s390x not found on PATH." >&2
        echo "  Fedora/RHEL: sudo dnf install qemu-system-s390x" >&2
        exit 1
    fi
    echo "Host arch: $HOST_ARCH — calling $QEMU_S390X directly (no libvirt)."
    echo "NOTE: Software emulation is ~5-10x slower than native KVM."
    echo "      Expected build time: 1-3 hours. Output is identical to KVM."

    # ── Step 1: create the output disk image ─────────────────────────────────
    qemu-img create -f qcow2 "$OUTPUT_DISK" "${DISK_SIZE_GB}G"

    # ── Step 2: extract kernel + initrd from the ISO ─────────────────────────
    # virt-install --location does exactly this: copies kernel.img and
    # initrd.img out of the ISO's images/cdboot/ (s390x installer boot path).
    #
    # RHEL 10 s390x DVD ISO boot directory discovery:
    #   Primary:  images/cdboot/kernel.img + initrd.img
    #   Fallback: images/kernel.img + initrd.img
    # Print the full ISO images/ tree so failures are immediately diagnosable.
    echo "--- ISO boot directory layout (images/) ---"
    find "$ISO_MOUNT/images" -maxdepth 2 2>/dev/null | sort || true
    echo "---"

    BOOT_DIR="$ISO_MOUNT/images/cdboot"
    if [[ ! -d "$BOOT_DIR" ]]; then
        echo "WARNING: images/cdboot/ not found — falling back to images/"
        BOOT_DIR="$ISO_MOUNT/images"
    fi

    echo "Using BOOT_DIR: $BOOT_DIR"
    echo "  kernel.img: $(ls -lh "$BOOT_DIR/kernel.img" 2>/dev/null || echo 'NOT FOUND')"
    echo "  initrd.img: $(ls -lh "$BOOT_DIR/initrd.img" 2>/dev/null || echo 'NOT FOUND')"

    if [[ ! -f "$BOOT_DIR/kernel.img" ]]; then
        echo "ERROR: kernel.img not found in $BOOT_DIR" >&2
        echo "  Full ISO images/ tree:" >&2
        find "$ISO_MOUNT/images" 2>/dev/null | sort >&2
        exit 1
    fi
    if [[ ! -f "$BOOT_DIR/initrd.img" ]]; then
        echo "ERROR: initrd.img not found in $BOOT_DIR" >&2
        exit 1
    fi

    KS_INITRD_DIR=$(mktemp -d /tmp/ks-initrd.XXXXXX)
    KERNEL_IMG="$KS_INITRD_DIR/kernel.img"
    INITRD_IMG="$KS_INITRD_DIR/initrd.img"
    cp "$BOOT_DIR/kernel.img" "$KERNEL_IMG"
    cp "$BOOT_DIR/initrd.img" "$INITRD_IMG"

    echo "Copied kernel: $(ls -lh "$KERNEL_IMG") — $(file "$KERNEL_IMG" | cut -d: -f2-)"
    echo "Copied initrd: $(ls -lh "$INITRD_IMG")"

    # ── Step 3: inject kickstart into initrd ─────────────────────────────────
    # virt-install --initrd-inject appends a cpio archive containing the
    # kickstart file to the end of initrd.img (initrd is a concatenated cpio).
    # The kernel unpacks all cpio members in order; the last one wins.
    # Anaconda finds the file at /rhel10-s390x-dm-root.ks in the initrd.
    INJECT_DIR=$(mktemp -d /tmp/ks-inject.XXXXXX)
    cp "$KS_FILE" "$INJECT_DIR/$(basename "$KS_FILE")"
    ( cd "$INJECT_DIR" && find . | cpio --quiet -o -H newc ) >> "$INITRD_IMG"

    # ── Step 4: run the Anaconda installer VM ────────────────────────────────
    # Flags:
    #   -machine s390-ccw-virtio   s390x system type (CCW bus, virtio devices)
    #   -cpu max                   best emulated s390x CPU features
    #   -m                         RAM for Anaconda (needs ≥4 GiB)
    #   -nographic -nodefaults     headless; no spurious devices
    #   -serial mon:stdio          Anaconda console on stdout; also monitor
    #   -drive file=,if=none,...   virtio-blk disks attached via device below
    #   -device virtio-blk-ccw    s390x virtio block device (CCW channel)
    #   -netdev user/-device virtio-net-ccw
    #                              NAT NIC (DHCP+DNS via the host).  REQUIRED:
    #                              kickstart %post runs `subscription-manager
    #                              register` under `%post --erroronfail`.  With
    #                              no NIC it fails ("Name or service not known"),
    #                              Anaconda stops at "Press ENTER to exit" and,
    #                              with no stdin, waits forever.
    #   -kernel/-initrd/-append    direct-kernel boot with injected kickstart
    #
    # The kernel cmdline mirrors what build-s390x-base-image.sh passes via
    # virt-install --extra-args on s390x:
    #   console=ttysclp0           s390x line-mode console
    #   inst.repo=hd:LABEL=...     Anaconda finds stage2 on the ISO disk
    #   inst.ks=file:/...          kickstart is in initrd
    #   inst.ks.org_id/key         RHSM credentials forwarded to %post
    "$QEMU_S390X" \
        -machine s390-ccw-virtio \
        -cpu max \
        -m "${VM_MEMORY_MB}M" \
        -nographic \
        -nodefaults \
        -serial mon:stdio \
        -drive "file=${OUTPUT_DISK},if=none,id=drive-vda,format=qcow2,cache=unsafe" \
        -device "virtio-blk-ccw,drive=drive-vda,id=vda" \
        -drive "file=${ISO_PATH},if=none,id=drive-vdb,format=raw,readonly=on,cache=none" \
        -device "virtio-blk-ccw,drive=drive-vdb,id=vdb" \
        -netdev user,id=net0 \
        -device virtio-net-ccw,netdev=net0 \
        -kernel "$KERNEL_IMG" \
        -initrd "$INITRD_IMG" \
        -append "console=ttysclp0 inst.repo=hd:LABEL=${ISO_LABEL}:/ inst.ks=file:/$(basename "$KS_FILE") inst.ks.org_id=${ORG_ID} inst.ks.activation_key=${ACTIVATION_KEY} inst.text quiet" \
    || { RC=$?; rm -rf "$KS_INITRD_DIR" "$INJECT_DIR"; exit $RC; }

    rm -rf "$KS_INITRD_DIR" "$INJECT_DIR"
fi

echo ""
echo "=== Build complete ==="
echo "Output: $OUTPUT_DISK"
ls -lh "$OUTPUT_DISK"
