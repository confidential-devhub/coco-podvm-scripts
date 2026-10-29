#!/bin/bash
# s390x variant of coco-components.sh
# Installs CoCo guest components into a given s390x disk image via virt-customize.
#
# Differences from the x86_64 version:
#   - Calls script-disk-mods-s390x.sh  (no shim CSV)
#   - Calls podvm_maker-s390x.sh       (s390x CentOS mirror, ttysclp0 console)

INPUT_IMAGE=$1

SCRIPT_FOLDER=${SCRIPT_FOLDER:-$(dirname "$0")}
SCRIPT_FOLDER=$(realpath "$SCRIPT_FOLDER")

PODVM_BINARY_DEF=quay.io/redhat-user-workloads/ose-osc-tenant/osc-podvm-payload@sha256:e796ec80f0ae36153be8ca0f550c68e340d8117f00193f2b224c0478b2c06bd7
PODVM_BINARY_LOCATION_DEF=/podvm-binaries.tar.gz
PAUSE_BUNDLE_DEF=quay.io/redhat-user-workloads/ose-osc-tenant/osc-podvm-payload@sha256:e796ec80f0ae36153be8ca0f550c68e340d8117f00193f2b224c0478b2c06bd7
PAUSE_BUNDLE_LOCATION_DEF=/pause-bundle.tar.gz

function local_help()
{
    echo "Usage: $0 <INPUT_IMAGE>"
    echo "Usage: $0 help"
    echo ""
    echo "Extract and install all CoCo guest components into a given s390x disk image."
    echo ""
    echo "Options (define them as variables):"
    echo "ARTIFACTS_FOLDER:      optional  - podvm binaries/pause bundle location. Default: $SCRIPT_FOLDER/coco/podvm"
    echo "PODVM_BINARY:          optional  - registry containing podvm binary. Default: $PODVM_BINARY_DEF"
    echo "PODVM_BINARY_LOCATION: optional  - path inside container for podvm binary. Default: $PODVM_BINARY_LOCATION_DEF"
    echo "PAUSE_BUNDLE:          optional  - registry containing pause bundle. Default: $PAUSE_BUNDLE_DEF"
    echo "PAUSE_BUNDLE_LOCATION: optional  - path inside container for pause bundle. Default: $PAUSE_BUNDLE_LOCATION_DEF"
    echo "ROOT_PASSWORD:         optional  - set root password. Default: disabled"
}

PODVM_BINARY=${PODVM_BINARY:-"$PODVM_BINARY_DEF"}
PODVM_BINARY_LOCATION=${PODVM_BINARY_LOCATION:-"$PODVM_BINARY_LOCATION_DEF"}
PAUSE_BUNDLE=${PAUSE_BUNDLE:-"$PAUSE_BUNDLE_DEF"}
PAUSE_BUNDLE_LOCATION=${PAUSE_BUNDLE_LOCATION:-"$PAUSE_BUNDLE_LOCATION_DEF"}
ARTIFACTS_FOLDER=${ARTIFACTS_FOLDER:-"$SCRIPT_FOLDER/coco/podvm"}

if [ -z "${INPUT_IMAGE}" ]; then
    local_help
    exit 1
fi

if [[ "$INPUT_IMAGE" == "help" ]]; then
    local_help
    exit 0
fi

function print_params()
{
    echo ""
    echo "INPUT_IMAGE:           $INPUT_IMAGE"
    echo "SCRIPT_FOLDER:         $SCRIPT_FOLDER"
    echo "ARTIFACTS_FOLDER:      $ARTIFACTS_FOLDER"
    echo "PODVM_BINARY:          $PODVM_BINARY"
    echo "PODVM_BINARY_LOCATION: $PODVM_BINARY_LOCATION"
    echo "PAUSE_BUNDLE:          $PAUSE_BUNDLE"
    echo "PAUSE_BUNDLE_LOCATION: $PAUSE_BUNDLE_LOCATION"
    echo "ROOT_PASSWORD:         $ROOT_PASSWORD"
    echo ""
}

INPUT_IMAGE=$(realpath "$INPUT_IMAGE")

print_params

export PODVM_BINARY
export PODVM_BINARY_LOCATION
export PAUSE_BUNDLE
export PAUSE_BUNDLE_LOCATION
export DEST_PATH=$ARTIFACTS_FOLDER

# The Konflux builder image already ships both tarballs in /payload (copied
# from the payload image at build time) and has no podman, so get-artifacts.sh
# cannot pull them.  Stage them into ARTIFACTS_FOLDER first; get-artifacts.sh
# skips any download whose target file already exists.
PAYLOAD_DIR=${PAYLOAD_DIR:-/payload}
for _loc in "$PODVM_BINARY_LOCATION" "$PAUSE_BUNDLE_LOCATION"; do
    _f=$(basename "$_loc")
    if [[ ! -e "$ARTIFACTS_FOLDER/$_f" && -f "$PAYLOAD_DIR/$_f" ]]; then
        echo "Using $PAYLOAD_DIR/$_f"
        cp "$PAYLOAD_DIR/$_f" "$ARTIFACTS_FOLDER/$_f"
    fi
done

# get-artifacts.sh ends with an '[[ -e ]] && ...' list, so its exit status is
# non-zero when everything is already present.  Judge success by the files.
"$ARTIFACTS_FOLDER/get-artifacts.sh" || true

# Build luks-config.tar.gz from the luks-scratch tree
"$ARTIFACTS_FOLDER/luks-scratch/build.sh" || exit 1

# Fail fast: a missing artifact must not let the chroot work continue and
# silently produce an image without the CoCo components.
for _f in podvm-binaries.tar.gz pause-bundle.tar.gz luks-config.tar.gz; do
    if [[ ! -s "$ARTIFACTS_FOLDER/$_f" ]]; then
        echo "ERROR: required artifact $ARTIFACTS_FOLDER/$_f is missing or empty." >&2
        exit 1
    fi
done

echo ""
ls "$ARTIFACTS_FOLDER"
echo ""

# ── Execution strategy: s390x native vs x86 cross-build ──────────────────────
# On s390x: use virt-customize (libguestfs boots a native KVM s390x appliance).
# On x86:   libguestfs only builds an x86_64 supermin appliance — it cannot boot
#           under qemu-system-s390x. Instead, mount the image via NBD and use
#           chroot + qemu-s390x-static (binfmt_misc) to execute s390x binaries
#           directly on the x86 host kernel. No appliance VM is needed.
HOST_ARCH=$(uname -m)

if [[ "$HOST_ARCH" == "s390x" ]]; then
    # ── Native s390x path: virt-customize ────────────────────────────────────
    SM_REGISTER=()
    EXTRA_ARGS=""
    [[ -n "$ROOT_PASSWORD" ]] && EXTRA_ARGS=" --root-password password:${ROOT_PASSWORD} "
    [[ -n "${ACTIVATION_KEY}" && -n "${ORG_ID}" ]] && \
        SM_REGISTER=(--run-command "subscription-manager register --org=${ORG_ID} --activationkey=${ACTIVATION_KEY}")

    # Note: --upload is used instead of --copy-in for the payload tarballs.
    # --copy-in wraps files in a host-side tar stream; on RHEL 10 s390x with
    # libguestfs-1.58.1 this fails for large files (tar_in = -1).
    # --upload uses a direct file transfer protocol that works for any size.
    virt-customize --memsize 8192 \
        "${SM_REGISTER[@]}" \
        --run "$ARTIFACTS_FOLDER/script-disk-mods-s390x.sh" \
        --upload "$ARTIFACTS_FOLDER/podvm-binaries.tar.gz:/tmp/podvm-binaries.tar.gz" \
        --upload "$ARTIFACTS_FOLDER/pause-bundle.tar.gz:/tmp/pause-bundle.tar.gz" \
        --upload "$ARTIFACTS_FOLDER/luks-config.tar.gz:/tmp/luks-config.tar.gz" \
        --run "$ARTIFACTS_FOLDER/podvm_maker-s390x.sh" \
        ${EXTRA_ARGS} \
        -a "$INPUT_IMAGE"

    [[ ${#SM_REGISTER[@]} -gt 0 ]] && \
        virt-customize --memsize 8192 --run-command "subscription-manager unregister" \
            -a "$INPUT_IMAGE" || true

else
    # ── Cross-arch x86 path: NBD mount + chroot + qemu-s390x-static ──────────
    # qemu-s390x-static + binfmt_misc lets the x86 host kernel transparently
    # execute s390x ELF binaries inside a chroot — no appliance VM required.
    QEMU_STATIC=/usr/local/bin/qemu-s390x-static
    if [[ ! -x "$QEMU_STATIC" ]]; then
        echo "ERROR: $QEMU_STATIC not found." >&2
        echo "  Build it from QEMU source:" >&2
        echo "    cd /path/to/qemu-9.1.0" >&2
        echo "    mkdir build-static && cd build-static" >&2
        echo "    ../configure --target-list=s390x-linux-user --static --disable-docs --disable-werror" >&2
        echo "    make -j\$(nproc)" >&2
        echo "    sudo cp qemu-s390x /usr/local/bin/qemu-s390x-static" >&2
        exit 1
    fi

    # Determine which NBD device to use (default nbd0 for CoCo stage; verity uses nbd4)
    NBD_DEV_COCO=${NBD_DEV_COCO:-0}
    NBD_DEVICE="/dev/nbd${NBD_DEV_COCO}"
    CHROOT_DIR=$(mktemp -d /tmp/coco-chroot.XXXXXX)

    # Chroot-only tweaks that must not survive into the final image:
    #   - /etc/resolv.conf  : the guest has no usable resolver in the chroot
    #   - 91-zipl.install   : zipl segfaults under qemu-user (exit 139) and
    #                         aborts every kernel rpm install/erase scriptlet.
    #                         zipl is run for real in the Stage 3 s390x VM.
    RESOLV_SAVED=0
    ZIPL_MASKED=0
    function coco_chroot_restore_guest() {
        if [[ $ZIPL_MASKED -eq 1 ]]; then
            rm -f "$CHROOT_DIR/etc/kernel/install.d/91-zipl.install"
            ZIPL_MASKED=0
        fi
        if [[ $RESOLV_SAVED -eq 1 ]]; then
            rm -f "$CHROOT_DIR/etc/resolv.conf"
            if [[ -e "$CHROOT_DIR/etc/resolv.conf.coco-orig" || -L "$CHROOT_DIR/etc/resolv.conf.coco-orig" ]]; then
                mv "$CHROOT_DIR/etc/resolv.conf.coco-orig" "$CHROOT_DIR/etc/resolv.conf"
            fi
            RESOLV_SAVED=0
        fi
    }

    function coco_chroot_cleanup() {
        echo "Cleaning up chroot at $CHROOT_DIR ..."
        coco_chroot_restore_guest
        # Remove the host emulator binary that was injected for binfmt_misc — it is
        # an x86 binary that must not end up in the published s390x image.
        rm -f "$CHROOT_DIR/usr/local/bin/qemu-s390x-static"
        # Unmount in reverse order; ignore errors (may already be unmounted)
        for mnt in proc sys dev/pts dev run tmp; do
            umount -R "$CHROOT_DIR/$mnt" 2>/dev/null || true
        done
        umount "$CHROOT_DIR" 2>/dev/null || true
        rmdir "$CHROOT_DIR" 2>/dev/null || true
        qemu-nbd --disconnect "$NBD_DEVICE" 2>/dev/null || true
        # Remove binfmt_misc registration added by this script
        if [[ -f /proc/sys/fs/binfmt_misc/qemu-s390x ]]; then
            echo -1 > /proc/sys/fs/binfmt_misc/qemu-s390x 2>/dev/null || true
        fi
    }
    trap coco_chroot_cleanup EXIT

    echo "Cross-arch CoCo install: NBD mount + chroot (host=$HOST_ARCH)"

    # 1. Connect image via NBD
    modprobe nbd max_part=16 2>/dev/null || true
    echo "Connecting $INPUT_IMAGE via $NBD_DEVICE ..."
    qemu-nbd -c "$NBD_DEVICE" -f qcow2 "$INPUT_IMAGE"
    sleep 2
    partprobe "$NBD_DEVICE" 2>/dev/null || true
    sleep 1

    # 2. Find root partition = partition 2 (Bug 19):
    #    vda1 = /boot-se (plain 128 MiB), vda2 = root data, vda3 = verity hash.
    #    Do NOT pick by size: vda1 is 128 MiB and could outrank a small hash
    #    partition, which would mount the wrong filesystem.
    NBD_BASE="${NBD_DEVICE#/dev/}"
    ROOT_PART=$(lsblk -o NAME -r "$NBD_DEVICE" \
        | tail -n +2 | grep -v "^${NBD_BASE} $" \
        | awk -v dev="$NBD_BASE" '$0 ~ dev "p?2$|" dev "2$" {print "/dev/"$1; exit}')
    if [[ -z "$ROOT_PART" ]]; then
        echo "Error: could not find root partition (p2) on $NBD_DEVICE" >&2
        exit 1
    fi
    echo "Root partition: $ROOT_PART"

    # 3. fsck + mount
    e2fsck -p "$ROOT_PART" 2>/dev/null || e2fsck -y "$ROOT_PART" || true
    mount "$ROOT_PART" "$CHROOT_DIR"

    # 4. Register qemu-s390x-static binfmt_misc so s390x ELFs execute transparently
    modprobe binfmt_misc 2>/dev/null || true
    mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc 2>/dev/null || true
    if [[ ! -f /proc/sys/fs/binfmt_misc/qemu-s390x ]]; then
        echo ':qemu-s390x:M::\x7fELF\x02\x02\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x16:\xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff:/usr/local/bin/qemu-s390x-static:' \
            > /proc/sys/fs/binfmt_misc/register
        echo "Registered binfmt_misc for s390x ELF."
    fi

    # 5. Copy qemu-s390x-static into the chroot (must be at same path as registered)
    mkdir -p "$CHROOT_DIR/usr/local/bin"
    cp "$QEMU_STATIC" "$CHROOT_DIR/usr/local/bin/qemu-s390x-static"

    # 6. Bind-mount host pseudo-filesystems into chroot
    mount --bind /proc  "$CHROOT_DIR/proc"
    mount --bind /sys   "$CHROOT_DIR/sys"
    mount --bind /dev   "$CHROOT_DIR/dev"
    mount --bind /dev/pts "$CHROOT_DIR/dev/pts"
    mount -t tmpfs tmpfs "$CHROOT_DIR/run"
    mount -t tmpfs tmpfs "$CHROOT_DIR/tmp"

    # 6b. DNS inside the chroot.  The guest's /etc/resolv.conf is a dangling
    #     symlink (-> /run/systemd/resolve/..., /run is a fresh tmpfs here), so
    #     RHSM, dnf and curl all fail with "Name or service not known".  Borrow
    #     the builder container's resolver config for the duration of the run.
    if [[ -e "$CHROOT_DIR/etc/resolv.conf" || -L "$CHROOT_DIR/etc/resolv.conf" ]]; then
        mv "$CHROOT_DIR/etc/resolv.conf" "$CHROOT_DIR/etc/resolv.conf.coco-orig"
    fi
    cp /etc/resolv.conf "$CHROOT_DIR/etc/resolv.conf"
    RESOLV_SAVED=1

    # 6c. Mask the zipl kernel-install hook (see comment above).  A symlink to
    #     /dev/null in /etc overrides the vendor file in /usr/lib.
    mkdir -p "$CHROOT_DIR/etc/kernel/install.d"
    ln -sf /dev/null "$CHROOT_DIR/etc/kernel/install.d/91-zipl.install"
    ZIPL_MASKED=1

    # 7. Copy artifact tarballs into chroot /tmp
    cp "$ARTIFACTS_FOLDER/podvm-binaries.tar.gz" "$CHROOT_DIR/tmp/" || exit 1
    cp "$ARTIFACTS_FOLDER/pause-bundle.tar.gz"   "$CHROOT_DIR/tmp/" || exit 1
    cp "$ARTIFACTS_FOLDER/luks-config.tar.gz"    "$CHROOT_DIR/tmp/" || exit 1

    # 8. Copy scripts into chroot /tmp (they reference each other by name)
    cp "$ARTIFACTS_FOLDER/script-disk-mods-s390x.sh" "$CHROOT_DIR/tmp/"
    cp "$ARTIFACTS_FOLDER/podvm_maker-s390x.sh"       "$CHROOT_DIR/tmp/"
    chmod +x "$CHROOT_DIR/tmp/"*.sh

    # 9. RHSM register (if credentials supplied)
    if [[ -n "${ACTIVATION_KEY}" && -n "${ORG_ID}" ]]; then
        echo "Registering with RHSM inside chroot ..."
        # Without registration dnf has no repos and the pinned kernel cannot be
        # installed, so a failed register must abort the build.
        chroot "$CHROOT_DIR" subscription-manager register \
            --org="${ORG_ID}" --activationkey="${ACTIVATION_KEY}" \
            || { echo "ERROR: RHSM registration inside chroot failed." >&2; exit 1; }
    fi

    # 9b. Force DNF to resolve packages for s390x, not the host arch (x86_64).
    #
    # Inside a chroot, uname -m returns the HOST kernel's architecture (x86_64).
    # DNF derives $basearch from uname -m, so without this override it resolves
    # and installs x86_64 RPMs (kernel, xmlsec1, ...) into the s390x
    # disk image — the installed binaries then cannot run on the guest at all.
    #
    # Setting arch=s390x in /etc/dnf/dnf.conf inside the chroot overrides the
    # uname -m lookup for the duration of the chroot scripts.  We append the
    # line (not overwrite) so any existing dnf.conf settings are preserved, and
    # remove it on the way out so the guest image's dnf.conf is clean at boot.
    DNF_CONF="$CHROOT_DIR/etc/dnf/dnf.conf"
    if grep -q '^arch\s*=' "$DNF_CONF" 2>/dev/null; then
        # Replace any existing arch= line (defensive: should not be set)
        sed -i 's|^arch\s*=.*|arch = s390x|' "$DNF_CONF"
        DNF_ARCH_INJECTED=replaced
    else
        echo 'arch = s390x' >> "$DNF_CONF"
        DNF_ARCH_INJECTED=appended
    fi
    echo "DNF arch override set (action=$DNF_ARCH_INJECTED):"
    grep '^arch' "$DNF_CONF" || true

    # Tell the guest scripts they run under qemu-user (zipl cannot work here).
    export COCO_CROSS_CHROOT=1

    # 10. Run script-disk-mods-s390x.sh inside chroot
    echo "Running script-disk-mods-s390x.sh inside chroot ..."
    chroot "$CHROOT_DIR" bash /tmp/script-disk-mods-s390x.sh \
        || { echo "ERROR: script-disk-mods-s390x.sh failed in chroot." >&2; exit 1; }

    # 11. Run podvm_maker-s390x.sh inside chroot
    echo "Running podvm_maker-s390x.sh inside chroot ..."
    chroot "$CHROOT_DIR" bash /tmp/podvm_maker-s390x.sh \
        || { echo "ERROR: podvm_maker-s390x.sh failed in chroot." >&2; exit 1; }

    # 11b. Remove the arch override so the guest image's dnf.conf is clean at boot.
    if [[ "$DNF_ARCH_INJECTED" == "appended" ]]; then
        sed -i '/^arch\s*=\s*s390x/d' "$DNF_CONF"
    elif [[ "$DNF_ARCH_INJECTED" == "replaced" ]]; then
        sed -i '/^arch\s*=/d' "$DNF_CONF"
    fi
    echo "DNF arch override removed from guest dnf.conf."

    # 12. Set root password if requested
    if [[ -n "$ROOT_PASSWORD" ]]; then
        echo "root:${ROOT_PASSWORD}" | chroot "$CHROOT_DIR" chpasswd
    fi

    # 13. RHSM unregister (needs the borrowed resolv.conf, so the guest's own
    #     resolv.conf / kernel-install hooks are restored afterwards, in
    #     coco_chroot_cleanup below).
    if [[ -n "${ACTIVATION_KEY}" && -n "${ORG_ID}" ]]; then
        echo "Unregistering RHSM inside chroot ..."
        chroot "$CHROOT_DIR" subscription-manager unregister || true
        chroot "$CHROOT_DIR" subscription-manager clean       || true
    fi

    # 14. Cleanup (trap handles unmount + NBD disconnect)
    echo "CoCo chroot install complete."
    trap - EXIT
    coco_chroot_cleanup
fi
