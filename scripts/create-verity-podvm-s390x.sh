#!/bin/bash
set -e

# Orchestrator for building a CoCo PodVM disk image on s390x.
# Mirrors create-verity-podvm.sh but wires up the s390x-specific
# coco-components and verity scripts.
#
# Cross-architecture (x86 host) support:
#   On a non-s390x host this script automatically exports LIBGUESTFS_HV and
#   LIBGUESTFS_BACKEND so that every virt-customize call in the sub-scripts
#   (coco-components-s390x.sh, verity-s390x.sh) launches an s390x libguestfs
#   appliance VM instead of the default x86_64 appliance.
#
#   Why LIBGUESTFS_HV is required on x86:
#     virt-customize runs commands (zipl, dracut, dnf, etc.) inside a tiny
#     "appliance" VM managed by libguestfs. Without LIBGUESTFS_HV the appliance
#     is x86_64 and cannot execute s390x ELF binaries — the x86_64 kernel returns
#     ENOEXEC. Setting LIBGUESTFS_HV=/usr/bin/qemu-system-s390x makes libguestfs
#     boot an s390x appliance instead; the qcow2 is attached as /dev/vda
#     (virtio-blk) which also satisfies zipl's block ioctl requirements.
#
#   See docs/s390x-build-on-x86/README.md for the full cross-build guide.

INPUT_IMAGE=$1

here=$(pwd)
SCRIPT_FOLDER=$(dirname "$0")
SCRIPT_FOLDER=$(realpath "$SCRIPT_FOLDER")

function local_help()
{
    echo "Usage: $0 <INPUT_IMAGE>"
    echo "Usage: $0 help"
    echo ""
    echo "Takes an s390x RHEL 10 disk image and:"
    echo "  1. Installs CoCo guest components (kata-agent, attestation-agent, etc.)"
    echo "  2. Patches BLS boot entries (root=/dev/mapper/root) and re-runs zipl"
    echo "  3. Applies dm-verity to the root partition (veritysetup format)"
    echo "  4. Prints the roothash — supply it to the VM at start time via"
    echo "     kernel cmdline (Kata Containers / cloud-init / Azure custom data)"
    echo ""
    echo "Options (define them as variables):"
    echo ""
    echo "WORK_FOLDER:            optional  - working directory. Default: temp dir in /tmp"
    echo ""
    echo "Verity options:"
    echo "RESIZE_DISK:            optional  - resize disk before applying verity. Default: yes"
    echo "NBD_DEV:                optional  - /dev/nbd\$NBD_DEV to use. Default: 0"
    echo "VERITY_SCRIPT_LOCATION: optional  - path to verity-s390x.sh. Default: \$SCRIPT_FOLDER/verity/verity-s390x.sh"
    echo "ROOT_PARTITION_UUID:    optional  - GPT root type UUID. Default: 08a7acea-624c-4a20-91e8-6e0fa67d23f9"
    echo ""
    echo "CoCo guest options:"
    echo "ARTIFACTS_FOLDER:       optional  - podvm binaries/pause bundle location"
    echo "PODVM_BINARY:           optional  - registry containing podvm binary"
    echo "PODVM_BINARY_LOCATION:  optional  - path inside container for podvm binary"
    echo "PAUSE_BUNDLE:           optional  - registry containing pause bundle"
    echo "PAUSE_BUNDLE_LOCATION:  optional  - path inside container for pause bundle"
    echo "ROOT_PASSWORD:          optional  - set root password. Default: disabled"
    echo ""
    echo "Cross-architecture:"
    echo "  On s390x: runs natively (libguestfs uses the default KVM appliance)."
    echo "  On x86_64: automatically sets LIBGUESTFS_HV=qemu-system-s390x so"
    echo "  virt-customize boots an s390x appliance for zipl/dracut/dnf."
    echo "  Requires: qemu-system-s390x installed on the x86 host."
    echo ""
    echo "Exiting"
}

if [ -z "${INPUT_IMAGE}" ]; then
    local_help
    exit 1
fi

if [[ "$INPUT_IMAGE" == "help" ]]; then
    local_help
    exit 0
fi

INPUT_IMAGE=$(realpath "$INPUT_IMAGE")

VERITY_SCRIPT_LOCATION=${VERITY_SCRIPT_LOCATION:-"$SCRIPT_FOLDER/verity/verity-s390x.sh"}
VERITY_SCRIPT_LOCATION=$(realpath "$VERITY_SCRIPT_LOCATION")

COCO_SCRIPT_LOCATION=${COCO_SCRIPT_LOCATION:-"$SCRIPT_FOLDER/coco/coco-components-s390x.sh"}
COCO_SCRIPT_LOCATION=$(realpath "$COCO_SCRIPT_LOCATION")

# ── Cross-architecture libguestfs configuration ───────────────────────────────
# When running on a non-s390x host, configure libguestfs to use qemu-system-s390x
# as the appliance hypervisor so that virt-customize can execute s390x binaries
# (zipl, dracut, dnf) inside the s390x appliance VM.
#
# LIBGUESTFS_HV     — overrides the hypervisor binary used to boot the appliance.
#                     On x86: a wrapper script that rewrites x86-only QEMU args
#                     to s390x equivalents before exec-ing qemu-system-s390x.
#                     libguestfs hardcodes -machine q35 (x86-only); s390x needs
#                     -machine s390-ccw-virtio. Setting LIBGUESTFS_HV to the
#                     wrapper lets libguestfs build its cmdline normally, and the
#                     wrapper performs the substitution transparently.
#                     On s390x: left unset (libguestfs default = KVM appliance)
#
# LIBGUESTFS_BACKEND — "direct" bypasses the libvirt daemon.  Required when
#                     running inside a container (no libvirtd) and recommended
#                     for host builds where libvirtd permission/socket issues
#                     would otherwise block appliance launch.
HOST_ARCH=$(uname -m)
if [[ "$HOST_ARCH" != "s390x" ]]; then
    QEMU_S390X=$(command -v qemu-system-s390x 2>/dev/null || true)
    if [[ -z "$QEMU_S390X" ]]; then
        echo "ERROR: qemu-system-s390x not found on PATH." >&2
        echo "  Install it first:" >&2
        echo "    Fedora/RHEL: sudo dnf install qemu-system-s390x" >&2
        echo "    Ubuntu:      sudo apt install qemu-system-misc" >&2
        echo "  See docs/s390x-build-on-x86/README.md for the full guide." >&2
        exit 1
    fi
    # libguestfs generates an x86-centric QEMU cmdline including -machine q35
    # which qemu-system-s390x rejects with "unsupported machine type".
    # Write a wrapper that replaces -machine and -cpu with s390x equivalents
    # and drops x86-only flags (-global kvm-pit.*) before exec-ing the binary.
    LIBGUESTFS_HV_WRAPPER="/usr/local/bin/qemu-s390x-libguestfs-wrapper"
    cat > "$LIBGUESTFS_HV_WRAPPER" << 'WRAPPER_EOF'
#!/bin/bash
# Auto-generated wrapper: rewrites libguestfs x86 machine args for qemu-system-s390x.
args=()
skip_next=0
for arg in "$@"; do
    if [[ $skip_next -eq 1 ]]; then
        skip_next=0
        continue
    fi
    case "$arg" in
        -machine) args+=("-machine" "s390-ccw-virtio"); skip_next=1 ;;
        -cpu)     args+=("-cpu" "max");                 skip_next=1 ;;
        -global)  skip_next=1 ;;  # drop -global kvm-pit.lost_tick_policy=discard
        *)        args+=("$arg") ;;
    esac
done
exec QEMU_S390X_PLACEHOLDER "${args[@]}"
WRAPPER_EOF
    # Inject the real qemu path (can contain spaces/special chars in path)
    sed -i "s|QEMU_S390X_PLACEHOLDER|${QEMU_S390X}|" "$LIBGUESTFS_HV_WRAPPER"
    chmod +x "$LIBGUESTFS_HV_WRAPPER"
    export LIBGUESTFS_HV="$LIBGUESTFS_HV_WRAPPER"
    export LIBGUESTFS_BACKEND=direct
    echo "Cross-arch mode: host=$HOST_ARCH — LIBGUESTFS_HV=$LIBGUESTFS_HV"
    echo "  Wrapper rewrites -machine q35 → s390-ccw-virtio for qemu-system-s390x."
    echo "  All virt-customize calls will use the s390x appliance (software emulation)."
else
    # On s390x: honour any pre-existing LIBGUESTFS_BACKEND (e.g. set by
    # Dockerfile.s390x), but do not override LIBGUESTFS_HV.
    export LIBGUESTFS_BACKEND=${LIBGUESTFS_BACKEND:-direct}
    echo "Native s390x mode: using KVM-accelerated libguestfs appliance."
fi

function print_params()
{
    echo ""
    echo "WORK_FOLDER:            $WORK_FOLDER"
    echo "INPUT_IMAGE:            $INPUT_IMAGE"
    echo "VERITY_SCRIPT_LOCATION: $VERITY_SCRIPT_LOCATION"
    echo "COCO_SCRIPT_LOCATION:   $COCO_SCRIPT_LOCATION"
    echo ""
}

function error_exit()
{
    echo "$1" 1>&2
    exit 1
}

function get_podvm_image_format()
{
    local image_path="$1"
    echo "Getting format of the PodVM image: ${image_path}"
    PODVM_IMAGE_FORMAT=$(qemu-img info --output json "${image_path}" | jq -r '.format') ||
        error_exit "Failed to get podvm image info"

    if [[ "${image_path}" == *.vhd ]] && [[ "${PODVM_IMAGE_FORMAT}" == "raw" ]]; then
        PODVM_IMAGE_FORMAT="vhd"
    fi

    echo "PodVM image format: ${PODVM_IMAGE_FORMAT}"
    export PODVM_IMAGE_FORMAT
}

function get_input_img_format()
{
    get_podvm_image_format "$1"

    case "${PODVM_IMAGE_FORMAT}" in
    "qcow2") DISK_FORMAT="qcow2" ;;
    "raw")   DISK_FORMAT="raw"   ;;
    "vhd")   DISK_FORMAT="vpc"   ;;
    *)       error_exit "Unsupported image format: ${PODVM_IMAGE_FORMAT}" ;;
    esac

    export DISK_FORMAT
}

function handle_exit()
{
    local rc=$?
    # Clean up the temp work directory whether the script exits cleanly,
    # is interrupted (Ctrl-C), or fails mid-run (set -e triggers EXIT).
    if [[ -n "$WORK_FOLDER" && -d "$WORK_FOLDER" ]]; then
        rm -rf "$WORK_FOLDER"
    fi
    cd "$here"
    exit $rc
}

WORK_FOLDER=${WORK_FOLDER:-$(mktemp -d)}
WORK_FOLDER=$(realpath "$WORK_FOLDER")

print_params

cd "$WORK_FOLDER"

trap handle_exit SIGINT
trap handle_exit EXIT

get_input_img_format "$INPUT_IMAGE"

echo "Applying CoCo guest components (s390x) ..."
export PODVM_BINARY
export PODVM_BINARY_LOCATION
export PAUSE_BUNDLE
export PAUSE_BUNDLE_LOCATION
export ARTIFACTS_FOLDER
export SCRIPT_FOLDER
export ROOT_PASSWORD
"$COCO_SCRIPT_LOCATION" "$INPUT_IMAGE"
echo ""

echo "Applying dm-verity (s390x) ..."
export DISK_FORMAT
export RESIZE_DISK
export NBD_DEV
export VERITY_FOLDER=$WORK_FOLDER
export ROOT_PARTITION_UUID
"$VERITY_SCRIPT_LOCATION" "$INPUT_IMAGE"
echo ""

cd - > /dev/null

echo "Process completed!"
echo "Your s390x disk image now has CoCo components and dm-verity enabled."
