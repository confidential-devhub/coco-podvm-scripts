#! /bin/bash

here=`pwd`
SCRIPT_FOLDER=$(dirname $0)
SCRIPT_FOLDER=$(realpath $SCRIPT_FOLDER)

OUT_FOLDER=$1

function local_help()
{
    echo "Usage: $0 <OUTPUT_FOLDER>"
    echo "Usage: $0 help"
    echo ""
    echo "The purpose of this script is to create a private key and public DER and PEM certs."
    echo "The only input command is to specify where to store the key and certs".
    echo ""
    echo "Options (define them as variable):"
    echo "SB_CERT_NAME:               optional  - name of the secureboot certificate added into the gallery. Default: My custom certificate"
    echo ""
    echo "Exiting"
}

SB_CERT_NAME=${SB_CERT_NAME:-"My custom certificate"}

if [ -z ${OUT_FOLDER} ]; then
    OUT_FOLDER=$(dirname $SCRIPT_FOLDER)/certs
    mkdir -p $OUT_FOLDER
    echo "Defaulting OUT_FOLDER to $OUT_FOLDER"
fi

if [[ $OUT_FOLDER == "help" ]]; then
    local_help
    exit 0
fi

function create_sb_cert()
{
    echo "Creating a new certificate PEM, DER and key"
    openssl req -quiet -newkey rsa:4096 -nodes -keyout $IMAGE_PRIVATE_KEY -new -x509 -sha256 -subj "/CN=$SB_CERT_NAME/" --outform DER -out $IMAGE_CERTIFICATE_DER
    openssl x509 -inform DER -in $IMAGE_CERTIFICATE_DER -outform PEM -out $IMAGE_CERTIFICATE_PEM
}

IMAGE_CERTIFICATE_DER=$OUT_FOLDER/public_key.der
IMAGE_CERTIFICATE_PEM=$OUT_FOLDER/public_key.pem
IMAGE_PRIVATE_KEY=$OUT_FOLDER/private.key

echo ""
echo "Variable to export"
echo "export IMAGE_PRIVATE_KEY=$IMAGE_PRIVATE_KEY"
echo "export IMAGE_CERTIFICATE_DER=$IMAGE_CERTIFICATE_DER"
echo "export IMAGE_CERTIFICATE_PEM=$IMAGE_CERTIFICATE_PEM"
echo ""
create_sb_cert