#!/bin/bash

# Given a qcow2 and a DER certificate, upload it to Azure

INPUT_IMAGE=$1
IMAGE_CERTIFICATE_DER=$2

here=`pwd`
SCRIPT_FOLDER=${SCRIPT_FOLDER:-$(dirname $0)}
SCRIPT_FOLDER=$(realpath $SCRIPT_FOLDER)

function local_help()
{
    echo "Usage: $0 <INPUT_IMAGE> [<DER_CERTIFICATE>]"
    echo "Usage: $0 help"
    echo ""
    echo "The purpose of this script is to take a disk and:"
    echo "1. convert the disk into vhd"
    echo "2. if DER_CERTIFICATE is defined, create a deployment with a custom secureboot certificate"
    echo "3. upload the vhd to Azure"
    echo "4. create an Azure image gallery with that disk"
    echo ""
    echo "Options (define them as variable):"
    echo "AZURE_RESOURCE_GROUP:       mandatory - az resource group where to create the gallery"
    echo "AZURE_REGION:               optional  - az region where to create the gallery. Default: eastus"
    echo "IMAGE_GALLERY_NAME:         optional  - az gallery name. Default: my_gallery"
    echo "IMAGE_DEFINITION_NAME:      optional  - az image definition name. Default: podvm-image"
    echo "IMAGE_DEFINITION_PUBLISHER: optional  - az image definition publisher. Default: MyPublisher"
    echo "IMAGE_DEFINITION_OFFER:     optional  - az image definition offer. Default: My-PodVM"
    echo "IMAGE_DEFINITION_SKU:       optional  - az image definition sku. Default: My-PodVM"
    echo "IMAGE_VERSION:              optional  - az image version. Default: 1.0.0"
    echo "IMAGE_BLOB_NAME:            optional  - az image storage blob name. Default: dm-verity"
    echo "AZURE_SB_TEMPLATE:          optional  - az deployment template to automatically fill. Default: $SCRIPT_FOLDER/azure-sb-template.json"
    echo "AZURE_DEPLOYMENT_NAME:      optional  - az deployment name. Default: my-deployment"
    echo "WORK_FOLDER:                optional  - where to create artifacts. Defaults to a temp folder in /tmp"
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

# if [ -z ${IMAGE_CERTIFICATE_DER} ]; then
#     local_help
#     exit 1
# fi

if [ -z ${AZURE_RESOURCE_GROUP} ]; then
    echo "AZURE_RESOURCE_GROUP is unset. Set it with AZURE_RESOURCE_GROUP=your-rg"
    echo "Exiting"
    exit 1
fi

INPUT_IMAGE=$(realpath "$INPUT_IMAGE")

AZURE_REGION=${AZURE_REGION:-"eastus"}
IMAGE_GALLERY_NAME=${IMAGE_GALLERY_NAME:-"my_gallery"}
IMAGE_DEFINITION_NAME=${IMAGE_DEFINITION_NAME:-"podvm-image"}
IMAGE_BLOB_NAME=${IMAGE_BLOB_NAME:-"dm-verity"}
CONFIDENTIAL_COMPUTE_ENABLED="yes"
IMAGE_DEFINITION_PUBLISHER=${IMAGE_DEFINITION_PUBLISHER:-"MyPublisher"}
IMAGE_DEFINITION_OFFER=${IMAGE_DEFINITION_OFFER:-"My-PodVM"}
IMAGE_DEFINITION_SKU=${IMAGE_DEFINITION_SKU:-"My-PodVM"}
IMAGE_DEFINITION_OS_TYPE="Linux"
IMAGE_DEFINITION_OS_STATE="Generalized"
IMAGE_DEFINITION_VM_GENERATION="V2"
IMAGE_DEFINITION_ARCHITECTURE="x64"
IMAGE_VERSION=${IMAGE_VERSION:-"1.0.0"}
AZURE_SB_TEMPLATE=${AZURE_SB_TEMPLATE:-"$SCRIPT_FOLDER/azure-sb-template.json"}
AZURE_DEPLOYMENT_NAME=${AZURE_DEPLOYMENT_NAME:-"my-deployment"}

function print_params()
{
    echo ""
    echo "WORK_FOLDER: $WORK_FOLDER"
    echo "INPUT_IMAGE: $INPUT_IMAGE"
    echo "AZURE_REGION: $AZURE_REGION"
    echo "IMAGE_GALLERY_NAME: $IMAGE_GALLERY_NAME"
    echo "IMAGE_DEFINITION_NAME: $IMAGE_DEFINITION_NAME"
    echo "IMAGE_BLOB_NAME: $IMAGE_BLOB_NAME"
    echo "IMAGE_DEFINITION_PUBLISHER: $IMAGE_DEFINITION_PUBLISHER"
    echo "IMAGE_DEFINITION_OFFER: $IMAGE_DEFINITION_OFFER"
    echo "IMAGE_DEFINITION_SKU: $IMAGE_DEFINITION_SKU"
    echo "IMAGE_VERSION: $IMAGE_VERSION"
    if [[ -n "$IMAGE_CERTIFICATE_DER" ]]; then
        echo "IMAGE_CERTIFICATE_DER: $IMAGE_CERTIFICATE_DER"
    fi
    echo "AZURE_SB_TEMPLATE: $AZURE_SB_TEMPLATE"
    echo "AZURE_DEPLOYMENT_NAME: $AZURE_DEPLOYMENT_NAME"
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

# Function to convert qcow2 image to vhd image
# Input: qcow2 image
# Output: vhddisk image
function convert_qcow2_to_vhd() {
    qcow2disk=${1}
    path="$(dirname "${1}")"
    rawdisk="${path}/$(basename -s qcow2 "${1}")raw"
    vhddisk="${path}/$(basename -s qcow2 "${1}")vhd"
    echo "Qcow2 disk name: ${qcow2disk}"
    echo "Raw disk name: ${rawdisk}"
    echo "VHD disk name: ${vhddisk}"

    # Convert qcow2 to raw
    qemu-img convert -f qcow2 -O raw "${qcow2disk}" "${rawdisk}" ||
        error_exit "Failed to convert qcow2 to raw"

    # Convert raw to vhd
    resize_and_convert_raw_to_vhd_image "${rawdisk}"

    # Clean up the raw disk
    rm -f "${rawdisk}"

    echo "Successfully converted qcow2 to vhd image name: ${vhddisk}"
    export VHD_IMAGE_PATH="${vhddisk}"
}

# Function to resize and convert raw image to 1MB aligned vhd image for Azure
# Input: raw disk image
# Output: vhddisk image
function resize_and_convert_raw_to_vhd_image() {
    rawdisk=${1}
    path="$(dirname "${1}")"
    vhddisk="${path}/$(basename -s raw "${1}")vhd"

    echo "Raw disk name: ${rawdisk}"
    echo "VHD disk name: ${vhddisk}"

    MB=$((1024 * 1024))
    size=$(qemu-img info -f raw --output json "$rawdisk" | jq '."virtual-size"') ||
        error_exit "Failed to get raw disk size"

    echo "Raw disk size: ${size}"

    rounded_size=$(((size + MB - 1) / MB * MB))

    echo "Rounded Size = ${rounded_size}"

    echo "Rounding up raw disk to 1MB"
    qemu-img resize -f raw "$rawdisk" "$rounded_size" ||
        error_exit "Failed to resize raw disk"

    echo "Converting raw to vhd"
    qemu-img convert -f raw -o subformat=fixed,force_size -O vpc "$rawdisk" "$vhddisk" ||
        error_exit "Failed to convert raw to vhd"

    echo "Successfully converted raw to vhd image name: ${vhddisk}"
    export VHD_IMAGE_PATH="${vhddisk}"
}


function convert_podvm_image_to_vhd() {
    image_path=${1}

    # Get the podvm image type. This sets the PODVM_IMAGE_FORMAT global variable
    get_podvm_image_format "${image_path}"

    case "${PODVM_IMAGE_FORMAT}" in
    "qcow2")
        # Convert the qcow2 image to vhd
        convert_qcow2_to_vhd "${image_path}"
        ;;
    "raw")
        # Convert the raw image to vhd
        resize_and_convert_raw_to_vhd_image "${image_path}"
        ;;
    "vhd")
        echo "PodVM image is already a vhd image"
        export VHD_IMAGE_PATH="${image_path}"
        ;;
    *)
        error_exit "Invalid podvm image format: ${PODVM_IMAGE_FORMAT}"
        ;;
    esac

    echo "Successfully converted podvm image to vhd image name: ${VHD_IMAGE_PATH}"

}

# Function to upload the vhd to the volume
function upload_vhd_image() {
    echo "Uploading the vhd to the storage container"

    local vhd_path="${1}"
    local image_name="${2}"

    [[ -z "${vhd_path}" ]] && error_exit "VHD path is empty"

    # Create a storage account if it doesn't exist
    STORAGE_ACCOUNT_NAME="podvmartifacts$(date +%s)"
    az storage account create \
        --name "${STORAGE_ACCOUNT_NAME}" \
        --resource-group "${AZURE_RESOURCE_GROUP}" \
        --location "${AZURE_REGION}" \
        --sku Standard_LRS \
        --encryption-services blob ||
        error_exit "Failed to create the storage account"

    # Get storage account key
    STORAGE_ACCOUNT_KEY=$(az storage account keys list \
        --resource-group "${AZURE_RESOURCE_GROUP}" \
        --account-name "${STORAGE_ACCOUNT_NAME}" \
        --query '[0].value' \
        -o tsv) ||
        error_exit "Failed to get the storage account key"

    # Create a container in the storage account
    CONTAINER_NAME="podvm-artifacts"
    az storage container create \
        --name "${CONTAINER_NAME}" \
        --account-name "${STORAGE_ACCOUNT_NAME}" \
        --account-key "${STORAGE_ACCOUNT_KEY}" ||
        error_exit "Failed to create the storage container"

    # Upload the VHD to the storage container
    az storage blob upload --account-name "${STORAGE_ACCOUNT_NAME}" \
        --account-key "${STORAGE_ACCOUNT_KEY}" \
        --container-name "${CONTAINER_NAME}" \
        --file "${vhd_path}" \
        --name "${image_name}" ||
        error_exit "Failed to upload the VHD to the storage container"

    # Get the URL of the uploaded VHD
    VHD_URL=$(az storage blob url \
        --account-name "${STORAGE_ACCOUNT_NAME}" \
        --account-key "${STORAGE_ACCOUNT_KEY}" \
        --container-name "${CONTAINER_NAME}" \
        --name "${image_name}" -o tsv) ||
        error_exit "Failed to get the URL of the uploaded VHD"

    export VHD_URL

    echo "VHD uploaded successfully"
}


# Function to create Azure image gallery
# The gallery name is available in the variable IMAGE_GALLERY_NAME
function create_image_gallery() {
    echo "Creating Azure image gallery"

    # Check if the gallery already exists.
    az sig show --resource-group "${AZURE_RESOURCE_GROUP}" \
        --gallery-name "${IMAGE_GALLERY_NAME}"

    return_code=$?

    # If the gallery already exists, then skip creating the gallery
    if [[ "${return_code}" == "0" ]]; then
        echo "Gallery ${IMAGE_GALLERY_NAME} already exists. Skipping creating the gallery"
        return
    fi

    # Create Azure image gallery
    # If any error occurs, exit the script with an error message

    # Create the image gallery
    echo "Creating image gallery ${IMAGE_GALLERY_NAME}"

    az sig create --resource-group "${AZURE_RESOURCE_GROUP}" \
        --gallery-name "${IMAGE_GALLERY_NAME}" ||
        error_exit "Failed to create Azure image gallery"

    echo "Azure image gallery created successfully"

}

# Function to create Azure image definition
# The image definition name is available in the variable IMAGE_DEFINITION_NAME
# The VM generation is available in the variable IMAGE_DEFINITION_VM_GENERATION
# Create gallery to support confidential images if CONFIDENTIAL_COMPUTE_ENABLED is set to yes
function create_image_definition() {
    echo "Creating Azure image definition"

    # Check if the image definition already exists.
    az sig image-definition show --resource-group "${AZURE_RESOURCE_GROUP}" \
        --gallery-name "${IMAGE_GALLERY_NAME}" \
        --gallery-image-definition "${IMAGE_DEFINITION_NAME}"

    return_code=$?

    # Create Azure image definition if it doesn't exist

    if [[ "${return_code}" == "0" ]]; then
        echo "Image definition ${IMAGE_DEFINITION_NAME} already exists. Skipping creating the image definition"
        return
    fi

    if [[ "${CONFIDENTIAL_COMPUTE_ENABLED}" == "yes" ]]; then
        # Create the image definition. Add ConfidentialVmSupported feature
        az sig image-definition create --resource-group "${AZURE_RESOURCE_GROUP}" \
            --gallery-name "${IMAGE_GALLERY_NAME}" \
            --gallery-image-definition "${IMAGE_DEFINITION_NAME}" \
            --publisher "${IMAGE_DEFINITION_PUBLISHER}" \
            --offer "${IMAGE_DEFINITION_OFFER}" \
            --sku "${IMAGE_DEFINITION_SKU}" \
            --os-type "${IMAGE_DEFINITION_OS_TYPE}" \
            --os-state "${IMAGE_DEFINITION_OS_STATE}" \
            --hyper-v-generation "${IMAGE_DEFINITION_VM_GENERATION}" \
            --location "${AZURE_REGION}" \
            --architecture "${IMAGE_DEFINITION_ARCHITECTURE}" \
            --features SecurityType=ConfidentialVmSupported ||
            error_exit "Failed to create Azure image definition"

    else
        az sig image-definition create --resource-group "${AZURE_RESOURCE_GROUP}" \
            --gallery-name "${IMAGE_GALLERY_NAME}" \
            --gallery-image-definition "${IMAGE_DEFINITION_NAME}" \
            --publisher "${IMAGE_DEFINITION_PUBLISHER}" \
            --offer "${IMAGE_DEFINITION_OFFER}" \
            --sku "${IMAGE_DEFINITION_SKU}" \
            --os-type "${IMAGE_DEFINITION_OS_TYPE}" \
            --os-state "${IMAGE_DEFINITION_OS_STATE}" \
            --hyper-v-generation "${IMAGE_DEFINITION_VM_GENERATION}" \
            --location "${AZURE_REGION}" \
            --architecture "${IMAGE_DEFINITION_ARCHITECTURE}" ||
            error_exit "Failed to create Azure image definition"
    fi

    echo "Azure image definition created successfully"
}

# Function to retrieve the image id given gallery, image definition and image version
function get_image_id() {
    echo "Getting the image id"

    # Get the image id of the newly created image
    # If any error occurs, exit the script with an error message

    # Get the image id
    IMAGE_ID=$(az sig image-version show --resource-group "${AZURE_RESOURCE_GROUP}" \
        --gallery-name "${IMAGE_GALLERY_NAME}" \
        --gallery-image-definition "${IMAGE_DEFINITION_NAME}" \
        --gallery-image-version "${IMAGE_VERSION}" \
        --query "id" --output tsv) ||
        error_exit "Failed to get the image id"
    export IMAGE_ID

    echo "ID of the newly created image: ${IMAGE_ID}"
}

function create_signed_image_version()
{
    echo "Creating Azure image version with custom certificate"

    STORAGE_ID=$(az storage account show --name $STORAGE_ACCOUNT_NAME --resource-group $AZURE_RESOURCE_GROUP --query "id" -o tsv)

    BASE64_CERT=$(base64 -w0 $IMAGE_CERTIFICATE_DER)

    jq --arg name "$IMAGE_GALLERY_NAME/$IMAGE_DEFINITION_NAME/$IMAGE_VERSION" \
    --arg location "$AZURE_REGION" \
    --arg id "$STORAGE_ID" \
    --arg uri "$VHD_URL" \
    --arg value "$BASE64_CERT" \
    '.resources[0].name = $name |
    .resources[0].location = $location |
    .resources[0].properties.storageProfile.osDiskImage.source.id = $id |
    .resources[0].properties.storageProfile.osDiskImage.source.uri = $uri |
    .resources[0].properties.securityProfile.uefiSettings.additionalSignatures.db[0].value[0] = $value' \
   $AZURE_SB_TEMPLATE > az-deployment.json

   az deployment group create \
    --name $AZURE_DEPLOYMENT_NAME \
    --resource-group $AZURE_RESOURCE_GROUP \
    --template-file az-deployment.json ||
    error_exit "Failed to create the deployment group"
}

function create_unsigned_image_version()
{
    echo "Creating Azure image version"
    # Create the image version from the VHD
    az sig image-version create \
        --resource-group "${AZURE_RESOURCE_GROUP}" \
        --gallery-name "${IMAGE_GALLERY_NAME}" \
        --gallery-image-definition "${IMAGE_DEFINITION_NAME}" \
        --gallery-image-version "${IMAGE_VERSION}" \
        --os-vhd-uri "${VHD_URL}" \
        --os-vhd-storage-account "${STORAGE_ACCOUNT_NAME}" \
        --target-regions "${AZURE_REGION}" ||
        error_exit "Failed to create the image version"
}

function create_image_version()
{
    if [[ -n "${IMAGE_CERTIFICATE_DER}" ]]; then
        create_signed_image_version
    else
        create_unsigned_image_version
    fi
}

function delete_storage_account()
{
    az storage account delete \
        --name "${STORAGE_ACCOUNT_NAME}" \
        --resource-group "${AZURE_RESOURCE_GROUP}" \
        --yes ||
        error_exit "Failed to delete the storage account"
}

function handle_ctrlc()
{
    if [[ $storage_account_created == 1 ]]; then
        delete_storage_account
    fi

    # rm -rf $WORK_FOLDER/*.vhd
    rm -rf $WORK_FOLDER/*.raw
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


convert_podvm_image_to_vhd $INPUT_IMAGE
echo ""

upload_vhd_image $VHD_IMAGE_PATH $IMAGE_BLOB_NAME
storage_account_created=1
echo ""

create_image_gallery
echo ""

create_image_definition
echo ""

create_image_version
echo ""

storage_account_created=0
delete_storage_account
echo ""

get_image_id

cd -
# rm -rf $WORK_FOLDER/*.vhd
rm -rf $WORK_FOLDER/*.raw
echo "VHD generated file and deployment template are in $WORK_FOLDER"
