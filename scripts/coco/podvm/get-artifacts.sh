#! /bin/bash
set -e

if [ -z ${PODVM_BINARY} ]; then
    echo "Error: $PODVM_BINARY not defined!"
    exit 1
fi

if [ -z ${PODVM_BINARY_LOCATION} ]; then
    echo "Error: $PODVM_BINARY_LOCATION not defined!"
    exit 1
fi

if [ -z ${PAUSE_BUNDLE} ]; then
    echo "Error: $PAUSE_BUNDLE not defined!"
    exit 1
fi

if [ -z ${PAUSE_BUNDLE_LOCATION} ]; then
    echo "Error: $PAUSE_BUNDLE_LOCATION not defined!"
    exit 1
fi

if [ -z ${DEST_PATH} ]; then
    echo "Error: $DEST_PATH not defined!"
    exit 1
fi

export PODMAN_IGNORE_CGROUPSV1_WARNING=1

function download_and_extract()
{
    IMG=$1
    IMG_PATH=$2
    podman pull $IMG
    cid=$(podman create $IMG)
    podman cp "$cid":$IMG_PATH $DEST_PATH
}

function error_exit() {
    echo "$1" 1>&2
    exit 1
}

# Function to download and extract a container image.
# Accepts six arguments:
# 1. container_image_repo_url: The registry URL of the source container image.
# 2. image_tag: The tag of the source container image.
# 3. dest_image: The destination image name.
# 4. destination_path: The destination path where the image is to be extracted.
# 5. auth_json_file (optional): Path to the registry secret file to use for downloading the image.
function extract_container_image() {

    # Set the values required for the container image extraction.
    container_image_repo_url="${1}"
    image_tag="${2}"
    dest_image="${3}"
    destination_path="${4}"
    auth_json_file="${5}"

    # If arguments are not provided, exit the script with an error message
    [[ $# -lt 4 ]] &&
        error_exit "Usage: extract_container_image <container_image_repo_url> <image_tag> <dest_image> <destination_path> [registry_secret]"

    # Form the skopeo CLI. Add authfile if provided
    if [[ -n "${5}" ]]; then
        SKOPEO_CLI="skopeo copy --authfile ${auth_json_file}"
    else
        SKOPEO_CLI="skopeo copy"
    fi

    # Download the container image
    $SKOPEO_CLI "docker://${container_image_repo_url}:${image_tag}" "oci:${dest_image}:${image_tag}" --remove-signatures ||
        error_exit "Failed to download the container image"

    # Extract the container image using umoci into provided directory
    umoci unpack --rootless --image "${dest_image}:${image_tag}" "${destination_path}" ||
        error_exit "Failed to extract the container image"

    # Display the content of the destination_path
    echo "Extracted container image content:"
    ls -l "${destination_path}"

}

[[ ! -e $DEST_PATH/$PODVM_BINARY_LOCATION ]] && download_and_extract $PODVM_BINARY $PODVM_BINARY_LOCATION

# extract_container_image registry.redhat.io/openshift-sandboxed-containers/osc-podvm-payload-rhel9 1.8.1 /tmp/pause pause
[[ ! -e $DEST_PATH/$PAUSE_BUNDLE_LOCATION ]] && download_and_extract $PAUSE_BUNDLE $PAUSE_BUNDLE_LOCATION
