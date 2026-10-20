#!/bin/bash
# s390x variant of script-disk-mods.sh
# Runs inside the guest via virt-customize (called by coco-components-s390x.sh).
#
# Differences from x86_64:
#   - No EFI/shim/BOOTX64.CSV  — s390x boots via zipl, no shim
#   - No NVIDIA drivers         — NVIDIA has no s390x drivers
#   - No kernel-uki-virt        — does not exist on RHEL 10 s390x;
#                                 s390x uses plain kernel + zipl (no UKI)
#   - KERNEL_VERSION is auto-detected from the running guest if not set
set -ex

# Auto-detect the latest installed kernel if KERNEL_VERSION is not explicitly set.
# Priority: use the newest kernel-core package present in the guest.
if [[ -z "${KERNEL_VERSION:-}" ]]; then
    KERNEL_VERSION=$(rpm -q kernel-core \
        --queryformat '%{VERSION}-%{RELEASE}\n' 2>/dev/null \
        | sort -V | tail -1)
    echo "Auto-detected KERNEL_VERSION: ${KERNEL_VERSION}"
else
    echo "Using pinned KERNEL_VERSION: ${KERNEL_VERSION}"
fi

if [[ -z "${KERNEL_VERSION}" ]]; then
    echo "ERROR: Could not determine kernel version." >&2
    exit 1
fi

# Install the pinned kernel and module packages.
# On s390x: kernel, kernel-core, kernel-modules, kernel-modules-core,
# kernel-modules-extra — no kernel-uki-virt (does not exist on s390x).
dnf install -y \
    "kernel-${KERNEL_VERSION}" \
    "kernel-core-${KERNEL_VERSION}" \
    "kernel-modules-${KERNEL_VERSION}" \
    "kernel-modules-core-${KERNEL_VERSION}" \
    "kernel-modules-extra-${KERNEL_VERSION}" || true

# Remove all kernel packages that do NOT match KERNEL_VERSION.
# Keep kernel-tools and rescue entries — only remove versioned kernel packages.
echo "Removing non-pinned kernel packages:"
rpm -qa "kernel-*" \
    | grep -Ev "^kernel-(core|modules|modules-core|modules-extra|tools|devel)-${KERNEL_VERSION}" \
    | grep -Ev "^kernel-tools" \
    | grep -E "^kernel-" \
    | xargs -r rpm -e --nodeps || true

# Regenerate initramfs for the pinned kernel.
#
# Two s390x-specific requirements:
#
# 1. --add systemd-veritysetup
#    The veritysetup dracut module is not auto-included when the initramfs is
#    built because roothash= is not yet in the kernel cmdline at this stage
#    (verity is applied later by verity-s390x.sh). Without this flag the
#    module and its generator are absent from the initramfs and the verity
#    device is never assembled at boot.
#
# 2. parse-root.sh patch — bypass the dracut-initqueue wait for veritysetup
#    dracut-107 (RHEL 10.2) only exempts systemd-cryptsetup from the
#    devexists-/dev/mapper/root.sh finished-hook check. systemd-veritysetup is
#    missing from that exemption. Because remote-veritysetup.target is ordered
#    After=remote-fs-pre.target, which only starts after dracut-initqueue exits,
#    the boot deadlocks: dracut-initqueue waits for /dev/mapper/root, but
#    systemd-veritysetup@root.service can only run after dracut-initqueue.
#    The fix adds a one-line veritysetup bypass identical to the existing
#    cryptsetup bypass. The original file is restored immediately after dracut
#    so the host system is unchanged.

PARSE_ROOT=/usr/lib/dracut/modules.d/98dracut-systemd/parse-root.sh

if [[ -f "$PARSE_ROOT" ]]; then
    cp -p "$PARSE_ROOT" "${PARSE_ROOT}.orig"

    # Verify the exact pattern exists before patching so we fail loudly if
    # dracut has changed parse-root.sh in a future RHEL 10 update rather than
    # silently producing an un-patched initramfs (which causes the
    # dracut-initqueue deadlock at boot: /dev/mapper/root never appears).
    if ! grep -qF 'grep -q After=remote-fs-pre.target /run/systemd/generator/systemd-cryptsetup@*.service 2>/dev/null' "$PARSE_ROOT"; then
        echo "ERROR: parse-root.sh does not contain the expected cryptsetup pattern." >&2
        echo "       The dracut version on this image may have changed." >&2
        echo "       Inspect $PARSE_ROOT and update the sed pattern in this script." >&2
        exit 1
    fi

    sed -i \
        's|grep -q After=remote-fs-pre\.target /run/systemd/generator/systemd-cryptsetup@\*\.service 2>/dev/null|& \&\& ! grep -q After=remote-fs-pre.target /run/systemd/generator/systemd-veritysetup@*.service 2>/dev/null|' \
        "$PARSE_ROOT"

    # Confirm the patch actually landed.
    if ! grep -q 'systemd-veritysetup' "$PARSE_ROOT"; then
        echo "ERROR: sed ran without error but veritysetup bypass is absent from $PARSE_ROOT." >&2
        exit 1
    fi
    echo "parse-root.sh patched:"
    grep "veritysetup\|cryptsetup" "$PARSE_ROOT" || true
fi

# Bug #25 fix: patch systemd-volatile-root.service to use 'overlay' mode.
#
# The stock service unit hardcodes:
#   ExecStart=/usr/lib/systemd/systemd-volatile-root yes /sysroot
#
# 'yes' maps to VOLATILE_YES which calls make_volatile() — this uses MS_MOVE to
# relocate /sysroot. MS_MOVE requires the mount to be private or slave, but in
# the initrd PID 1 namespace /sysroot is a shared mount. MS_SLAVE on it returns
# EINVAL (logged as "ignoring"), leaving it shared, so MS_MOVE also returns EINVAL
# and the service exits 1, which blocks initrd-root-fs.target → emergency shell.
#
# 'overlay' maps to VOLATILE_OVERLAY which calls make_overlay() — this mounts a
# plain overlayfs (lowerdir=/sysroot, upperdir=tmpfs/upper, workdir=tmpfs/work)
# directly on /sysroot with no MS_MOVE at all. Works on shared mounts.
#
# Dracut copies /usr/lib/systemd/system/ units into the initramfs but does NOT
# automatically include /etc/systemd/system/ drop-ins. Patching the source unit
# directly (same pattern as parse-root.sh above) ensures the fix is baked in.
# The file is restored immediately after dracut so the installed system is unchanged.
# A persistent drop-in is also written to /etc/systemd/system/ so the service
# behaves correctly after pivot_root if systemd.volatile=overlay is on the cmdline.
VOLATILE_SVC=/usr/lib/systemd/system/systemd-volatile-root.service

cp -p "$VOLATILE_SVC" "${VOLATILE_SVC}.orig"

# Pre-flight: confirm the "yes" argument exists before patching.
# The stock unit may have "yes" at end-of-line (no trailing space), so the
# sed pattern must NOT require a trailing space after "yes".
if ! grep -qF 'systemd-volatile-root yes' "$VOLATILE_SVC"; then
    echo "ERROR: systemd-volatile-root.service does not contain the expected 'yes' argument." >&2
    echo "       Inspect $VOLATILE_SVC and update the sed pattern in this script." >&2
    exit 1
fi

# Replace "yes" with "overlay" regardless of whether "yes" is followed by
# a space, a newline, or additional arguments.
sed -i 's|systemd-volatile-root yes[[:space:]]*|systemd-volatile-root overlay |g' "$VOLATILE_SVC"

# Post-flight: confirm the patch landed.
if grep -q 'systemd-volatile-root yes' "$VOLATILE_SVC"; then
    echo "ERROR: sed ran but 'yes' is still present in systemd-volatile-root.service." >&2
    exit 1
fi
echo "systemd-volatile-root.service patched:"
grep "ExecStart" "$VOLATILE_SVC"

# Ensure the overlay kernel module is loaded before systemd-volatile-root runs.
#
# History of failed approaches:
#   - force_drivers in /etc/dracut.conf.d: only forces .ko into cpio, does not
#     change load ordering — systemd-modules-load.service races the service.
#   - --add-drivers + --install of modules-load.d conf: same race.
#   - Neither approach produced 00-load-overlay.sh in the initramfs pre-mount
#     hook dir (confirmed from boot log: only 99-mount-virtiofs.sh present).
#
# Correct fix: wrap the ExecStart in a shell one-liner that runs modprobe before
# invoking the real binary. The wrapper runs inside the same service unit so
# ordering is guaranteed — no race possible.
#
# The wrapper is installed into /usr/lib/systemd/ (alongside the binary) and
# the service unit's ExecStart is patched to call the wrapper instead.
# Both the wrapper and the patched unit are restored after dracut.

WRAPPER=/usr/lib/systemd/systemd-volatile-root-s390x
cat > "$WRAPPER" << 'EOF'
#!/bin/bash
# Load the overlay module required by VOLATILE_OVERLAY / make_overlay().
# Without this, mount("overlay",...) returns ENODEV and the service exits 1.
modprobe overlay 2>/dev/null || true
exec /usr/lib/systemd/systemd-volatile-root overlay /sysroot
EOF
chmod +x "$WRAPPER"

# Patch the service unit to call the wrapper (unit is already backed up above).
sed -i 's|ExecStart=/usr/lib/systemd/systemd-volatile-root overlay /sysroot|ExecStart=/usr/lib/systemd/systemd-volatile-root-s390x|g' "$VOLATILE_SVC"

# Confirm the patch landed.
if ! grep -q 'systemd-volatile-root-s390x' "$VOLATILE_SVC"; then
    echo "ERROR: wrapper patch did not land in $VOLATILE_SVC" >&2
    exit 1
fi
echo "systemd-volatile-root.service patched to use wrapper:"
grep "ExecStart" "$VOLATILE_SVC"

# Also write a persistent drop-in for the real root (post-pivot_root boots)
mkdir -p /etc/systemd/system/systemd-volatile-root.service.d
cat > /etc/systemd/system/systemd-volatile-root.service.d/s390x-overlay.conf << 'EOF'
[Service]
ExecStart=
ExecStart=/usr/lib/systemd/systemd-volatile-root overlay /sysroot
EOF

dracut --force --kver "${KERNEL_VERSION}.s390x" \
    --add "systemd-veritysetup" \
    --add-drivers "overlay" \
    --install "$WRAPPER"

# Restore: remove wrapper from host (it only belongs in the initramfs)
rm -f "$WRAPPER"

# Restore the original service unit so the installed system is unchanged
mv "${VOLATILE_SVC}.orig" "$VOLATILE_SVC"
echo "systemd-volatile-root.service restored."

if [[ -f "${PARSE_ROOT}.orig" ]]; then
    mv "${PARSE_ROOT}.orig" "$PARSE_ROOT"
    echo "parse-root.sh restored."
fi

# Update zipl boot record to reflect the pinned kernel
zipl --verbose

# xmlsec1 is required by the CoCo attestation flow
dnf install -y xmlsec1 xmlsec1-openssl

dnf clean all
