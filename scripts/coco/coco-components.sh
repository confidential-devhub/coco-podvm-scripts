#! /bin/bash

INPUT_IMAGE=$1

SCRIPT_FOLDER=${SCRIPT_FOLDER:-$(dirname $0)}
SCRIPT_FOLDER=$(realpath $SCRIPT_FOLDER)

PODVM_BINARY_DEF=quay.io/redhat-user-workloads/ose-osc-tenant/osc-podvm-payload:osc-podvm-payload-on-push-rmvjh-build-image-index
PODVM_BINARY_LOCATION_DEF=/podvm-binaries.tar.gz
PAUSE_BUNDLE_DEF=quay.io/redhat-user-workloads/ose-osc-tenant/osc-podvm-payload:osc-podvm-payload-on-push-rmvjh-build-image-index
PAUSE_BUNDLE_LOCATION_DEF=/pause-bundle.tar.gz

function local_help()
{
    echo "Usage: $0 <INPUT_IMAGE>"
    echo "Usage: $0 help"
    echo ""
    echo "The purpose of this script is to extract and install all CoCo guest"
    echo "components into a given disk"
    echo ""
    echo "Options (define them as variable):"
    echo "ARTIFACTS_FOLDER:      optional  - where the podvm binaries and pause bundle are. Default $SCRIPT_FOLDER/coco/podvm"
    echo "PODVM_BINARY:          optional - registry containing podvm binary. Default:$PODVM_BINARY_DEF "
    echo "PODVM_BINARY_LOCATION: optional - location in container containing podvm binary. Default: $PODVM_BINARY_LOCATION_DEF"
    echo "PAUSE_BUNDLE:          optional - registry containing pause bundle. Default: $PAUSE_BUNDLE_DEF"
    echo "PAUSE_BUNDLE_LOCATION: optional - location in container containing pause bundle. Default: $PAUSE_BUNDLE_LOCATION_DEF"
    echo "ROOT_PASSWORD:         optional - set root's password. Default: disabled"
}

PODVM_BINARY=${PODVM_BINARY:-"$PODVM_BINARY_DEF"}
PODVM_BINARY_LOCATION=${PODVM_BINARY_LOCATION:-"$PODVM_BINARY_LOCATION_DEF"}

PAUSE_BUNDLE=${PAUSE_BUNDLE:-"$PAUSE_BUNDLE_DEF"}
PAUSE_BUNDLE_LOCATION=${PAUSE_BUNDLE_LOCATION:-"$PAUSE_BUNDLE_LOCATION_DEF"}

ARTIFACTS_FOLDER=${ARTIFACTS_FOLDER:-"$SCRIPT_FOLDER/coco/podvm"}

if [ -z ${INPUT_IMAGE} ]; then
    local_help
    exit 1
fi

if [[ $INPUT_IMAGE == "help" ]]; then
    local_help
    exit 0
fi

function print_params()
{
    echo ""
    echo "INPUT_IMAGE: $INPUT_IMAGE"
    echo "SCRIPT_FOLDER: $SCRIPT_FOLDER"
    echo "ARTIFACTS_FOLDER: $ARTIFACTS_FOLDER"
    echo "PODVM_BINARY: $PODVM_BINARY"
    echo "PODVM_BINARY_LOCATION: $PODVM_BINARY_LOCATION"
    echo "PAUSE_BUNDLE: $PAUSE_BUNDLE"
    echo "PAUSE_BUNDLE_LOCATION: $PAUSE_BUNDLE_LOCATION"
    echo "ROOT_PASSWORD: $ROOT_PASSWORD"
    echo ""
}

INPUT_IMAGE=$(realpath "$INPUT_IMAGE")

print_params
echo ""

export PODVM_BINARY
export PODVM_BINARY_LOCATION
export PAUSE_BUNDLE
export PAUSE_BUNDLE_LOCATION
export DEST_PATH=$ARTIFACTS_FOLDER
$ARTIFACTS_FOLDER/get-artifacts.sh

# create luks-config.tar.gz
"$ARTIFACTS_FOLDER/luks-scratch/build.sh"

echo ""
ls $ARTIFACTS_FOLDER

echo ""
EXTRA_ARGS=""
SM_REGISTER=""
[[ -n "$ROOT_PASSWORD" ]] && EXTRA_ARGS=" --root-password password:${ROOT_PASSWORD} "
[[ -n "${ACTIVATION_KEY}" && -n "${ORG_ID}" ]] && SM_REGISTER=(--run-command "subscription-manager register --org=${ORG_ID} --activationkey=${ACTIVATION_KEY}") || SM_REGISTER=()

virt-customize --memsize 8192 \
    "${SM_REGISTER[@]}" \
    --copy-in $ARTIFACTS_FOLDER/podvm-binaries.tar.gz:/tmp/ \
    --copy-in $ARTIFACTS_FOLDER/pause-bundle.tar.gz:/tmp/ \
    --copy-in $ARTIFACTS_FOLDER/luks-config.tar.gz:/tmp/ \
    --run $ARTIFACTS_FOLDER/podvm_maker.sh \
    ${EXTRA_ARGS} \
    -a $INPUT_IMAGE

[[ ${#SM_REGISTER[@]} -gt 0 ]] && virt-customize --memsize 8192 --run-command "subscription-manager unregister" -a $INPUT_IMAGE || true
