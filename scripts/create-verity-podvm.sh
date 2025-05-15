#!/bin/bash
set -e

# required packages: jq, az, openssl, qemu-img, sbsigntools

INPUT_IMAGE=$1

here=`pwd`
SCRIPT_FOLDER=$(dirname $0)
SCRIPT_FOLDER=$(realpath $SCRIPT_FOLDER)

PODVM_BINARY_DEF=registry.redhat.io/openshift-sandboxed-containers/osc-podvm-payload-rhel9:1.9.0
PODVM_BINARY_LOCATION_DEF=/podvm-binaries.tar.gz
PAUSE_BUNDLE_DEF=quay.io/confidential-containers/podvm-binaries-ubuntu-amd64:v0.13.0
PAUSE_BUNDLE_LOCATION_DEF=/pause-bundle.tar.gz

function local_help()
{
    echo "Usage: $0 <INPUT_IMAGE>"
    echo "Usage: $0 help"
    echo ""
    echo "The purpose of this script is to take a disk and:"
    echo "1. create new certificates for the new image secureboot db, if not provided"
    echo "2. install coco guest components in the disk"
    echo "3. call verity script to verity protect the root disk"
    echo ""
    echo "Options (define them as variable):"
    echo "IMAGE_CERTIFICATE_PEM:      mandatory  - certificate in PEM format to upload in the gallery"
    echo "IMAGE_PRIVATE_KEY:          mandatory  - key to sign the verity cmdline addon"
    echo "WORK_FOLDER:                optional   - where to create artifacts. Defaults to a temp folder in /tmp"
    echo ""
    echo "Verity options (define them as variable):"
    echo ""
    echo "RESIZE_DISK:                optional   - whether to increase disk size by 10% to accomodate verity partition. Default: yes"
    echo "NBD_DEV:                    optional   - nbd\$NBD_DEV where to temporarily mount the disk. Default: 0"
    echo "VERITY_SCRIPT_LOCATION:     optional   - location of the verity.sh script. Default: $SCRIPT_FOLDER/verity/verity.sh"
    echo "ROOT_PARTITION_UUID:        optional   - UUID to find the root. Defaults to the x86_64 part type"
    echo ""
    echo "CoCo guest options (define them as variable):"
    echo ""
    echo "ARTIFACTS_FOLDER:           optional   - where the podvm binaries and pause bundle are. Default $SCRIPT_FOLDER/coco/podvm"
    echo "PODVM_BINARY:               optional   - registry containing podvm binary. Default:$PODVM_BINARY_DEF "
    echo "PODVM_BINARY_LOCATION:      optional - location in container containing podvm binary. Default: $PODVM_BINARY_LOCATION_DEF"
    echo "PAUSE_BUNDLE:               optional   - registry containing pause bundle. Default: $PAUSE_BUNDLE_DEF"
    echo "PAUSE_BUNDLE_LOCATION:      optional   - location in container containing pause bundle. Default: $PAUSE_BUNDLE_LOCATION_DEF"
    echo "ROOT_PASSWORD:              optional   - set root's password. Default: disabled"
    echo ""
    echo "Exiting"
}

if [ -z ${INPUT_IMAGE} ]; then
    local_help
    exit 1
fi

if [[ $INPUT_IMAGE == "help" ]]; then
    local_help
    exit 0
fi

if [[ -z "${IMAGE_PRIVATE_KEY}" || -z "${IMAGE_CERTIFICATE_PEM}" ]]; then
    echo "Error: define IMAGE_PRIVATE_KEY and IMAGE_CERTIFICATE_PEM."
    echo "It is possible to create certs with helpers/create-certs.sh"
    echo "Exiting."
    exit 1
fi

INPUT_IMAGE=$(realpath "$INPUT_IMAGE")

VERITY_SCRIPT_LOCATION=${VERITY_SCRIPT_LOCATION:-"$SCRIPT_FOLDER/verity/verity.sh"}
VERITY_SCRIPT_LOCATION=$(realpath "$VERITY_SCRIPT_LOCATION")

COCO_SCRIPT_LOCATION=${COCO_SCRIPT_LOCATION:-"$SCRIPT_FOLDER/coco/coco-components.sh"}
COCO_SCRIPT_LOCATION=$(realpath "$COCO_SCRIPT_LOCATION")

function print_params()
{
    echo ""
    echo "WORK_FOLDER: $WORK_FOLDER"
    echo "INPUT_IMAGE: $INPUT_IMAGE"
    echo "IMAGE_CERTIFICATE_PEM: $IMAGE_CERTIFICATE_PEM"
    echo "IMAGE_PRIVATE_KEY: $IMAGE_PRIVATE_KEY"
    echo "VERITY_SCRIPT_LOCATION: $VERITY_SCRIPT_LOCATION"
    echo "COCO_SCRIPT_LOCATION: $COCO_SCRIPT_LOCATION"
    echo ""
}

function error_exit() {
    echo "$1" 1>&2
    exit 1
}

# Function to get format of the podvm image
# Input: podvm image path
# Use qemu-img info to get the image info
# export the image format as PODVM_IMAGE_FORMAT
function get_podvm_image_format() {
    image_path="${1}"
    echo "Getting format of the PodVM image: ${image_path}"

    # jq -r when you want to output plain strings without quotes. Otherwise the string will be quoted
    PODVM_IMAGE_FORMAT=$(qemu-img info --output json "${image_path}" | jq -r '.format') ||
        error_exit "Failed to get podvm image info"

    # vhd images are also raw format. So check the file extension. It's crude but for
    # now it's good enough hopefully
    if [[ "${image_path}" == *.vhd ]] && [[ "${PODVM_IMAGE_FORMAT}" == "raw" ]]; then
        PODVM_IMAGE_FORMAT="vhd"
    fi

    echo "PodVM image format for ${image_path}: ${PODVM_IMAGE_FORMAT}"
    export PODVM_IMAGE_FORMAT
}

function get_input_img_format() {

    get_podvm_image_format $1

    case "${PODVM_IMAGE_FORMAT}" in
    "qcow2")
        DISK_FORMAT="qcow2"
        ;;
    "raw")
        DISK_FORMAT="raw"
        ;;
    "vhd")
        DISK_FORMAT="vpc"
        ;;
    *)
        error_exit "Invalid podvm image format: ${PODVM_IMAGE_FORMAT}"
        ;;
    esac

    export DISK_FORMAT
}

function handle_ctrlc()
{
    cd $here
    exit 0
}

WORK_FOLDER=${WORK_FOLDER:-$(mktemp -d)}
WORK_FOLDER=$(realpath "$WORK_FOLDER")

print_params

cd $WORK_FOLDER

storage_account_created=0

trap handle_ctrlc SIGINT
trap handle_ctrlc EXIT

get_input_img_format $INPUT_IMAGE

echo "Applying CoCo guest components..."
export PODVM_BINARY
export PODVM_BINARY_LOCATION
export PAUSE_BUNDLE
export PAUSE_BUNDLE_LOCATION
export ARTIFACTS_FOLDER
export SCRIPT_FOLDER
export ROOT_PASSWORD
$COCO_SCRIPT_LOCATION $INPUT_IMAGE
echo ""

echo "Calling verity..."
export DISK_FORMAT
export RESIZE_DISK
export SB_PRIVATE_KEY=$IMAGE_PRIVATE_KEY
export SB_CERTIFICATE=$IMAGE_CERTIFICATE_PEM
export NBD_DEV
export VERITY_FOLDER=$WORK_FOLDER
export ROOT_PARTITION_UUID
$VERITY_SCRIPT_LOCATION $INPUT_IMAGE
echo ""

cd - > /dev/null
rm -rf $WORK_FOLDER

echo "Process completed!"
echo "Your input qcow2 is now a coco-podvm with dm-verity enabled."