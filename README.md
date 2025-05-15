# How to create a dm-verity image via container

1. Download official RHEL ISO and build a CVM with `ks/rhel9-dm-root.ks`:
```
ISO_PATH=RHEL-9.6.0-x86_64-dvd1.iso
KS_LOCATION=ks/rhel9-dm-root.ks

virt-install --virt-type kvm --os-variant rhel9.0 --arch x86_64 --boot uefi --name rhel-uki --memory 8192 --location $ISO_PATH --disk bus=scsi,size=5 --initrd-inject=$KS_LOCATION --nographics --extra-args "console=ttyS0 inst.ks=file:/rhel9-dm-root.ks" --transient
```

2. Do custom modifications in the image

3. If not available, generate private key, PEM and DER certificates using `helpers/create-certs.sh`
```
Usage: ./helpers/create-certs.sh <OUTPUT_FOLDER>
Usage: ./helpers/create-certs.sh help

The purpose of this script is to create a private key and public DER and PEM certs.
The only input command is to specify where to store the key and certs.

Options (define them as variable):
SB_CERT_NAME:               optional  - name of the secureboot certificate added into the gallery. Default: My custom certificate
```

4. Build the container (if `dnf install` fails, make sure podman has logged into your RHEL account)
```
sudo podman build my-coco-podvm .
```

5. Export the following mandatory variables
```
QCOW2=path/where/qcow2/is
IMAGE_CERTIFICATE_PEM=path/where/pem_cert/is
IMAGE_PRIVATE_KEY=path/where/private_key/is
```

6. Optionally, define additional variables used by `scripts/create-verity-podvm.sh` running inside the container: (usage message available also with `create-verity-podvm.sh help`)
```
Usage: ./create-verity-podvm.sh <INPUT_IMAGE>
Usage: ./create-verity-podvm.sh help

The purpose of this script is to take a disk and:
1. create new certificates for the new image secureboot db, if not provided
2. install coco guest components in the disk
3. call verity script to verity protect the root disk

Options (define them as variable):
IMAGE_CERTIFICATE_DER:      mandatory  - certificate in DER format to upload in the gallery. Default: generate a new one
IMAGE_CERTIFICATE_PEM:      mandatory  - certificate in PEM format to upload in the gallery. Default: generate a new one
IMAGE_PRIVATE_KEY:          optional   - key to sign the verity cmdline addon. Default: generate a new one
SB_CERT_NAME:               optional   - name of the secureboot certificate added into the gallery. Default: My custom certificate
WORK_FOLDER:                optional   - where to create artifacts. Defaults to a temp folder in /tmp

Verity options (define them as variable):
RESIZE_DISK:                optional   - whether to increase disk size by 10% to accomodate verity partition. Default: yes
NBD_DEV:                    optional   - nbd$NBD_DEV where to temporarily mount the disk. Default: 0
VERITY_SCRIPT_LOCATION:     optional   - location of the verity.sh script. Default: ./verity.sh
ROOT_PARTITION_UUID:        optional   - UUID to find the root. Defaults to the x86_64 part type

CoCo guest options (define them as variable):

ARTIFACTS_FOLDER:           optional   - where the podvm binaries and pause bundle are. Default ./coco/podvm
PODVM_BINARY:               optional   - registry containing podvm binary. Default:registry.redhat.io/openshift-sandboxed-containers/osc-podvm-payload-rhel9:1.9.0
PODVM_BINARY_LOCATION:      optional   - location in container containing podvm binary. Default: /podvm-binaries.tar.gz
PAUSE_BUNDLE:               optional   - registry containing pause bundle. Default: quay.io/confidential-containers/podvm-binaries-ubuntu-amd64:v0.13.0
PAUSE_BUNDLE_LOCATION:      optional   - location in container containing pause bundle. Default: /pause-bundle.tar.gz
ROOT_PASSWORD:              optional   - set root's password. Default: disabled

```

7. Run the container. To add the optional exported variables, just add `-e YOUR_VAR=$YOUR_VAR`.
```
sudo podman run --rm \
    --privileged \
    -v $QCOW2:/disk.qcow2 \
    -v $IMAGE_CERTIFICATE_PEM:/public.pem \
    -v $IMAGE_PRIVATE_KEY:/private.key \
    -v /lib/modules:/lib/modules \
    --user 0 \
    --security-opt=apparmor=unconfined \
    --security-opt=seccomp=unconfined \
    --mount type=bind,source=/dev,target=/dev \
    --mount type=bind,source=/run/udev,target=/run/udev \
    coco-podvm
```
As a result, the input image will contain coco-components and be dm-verity protected.

8. Optionally, upload yourself the image on Azure image gallery using `azure/upload-azure.sh`. In order to use that script, define the following variables (usage message available also by running `azure/upload-azure.sh help`):
```
Usage: azure/upload-azure.sh <INPUT_IMAGE> <DER_CERTIFICATE>
Usage: azure/upload-azure.sh help

The purpose of this script is to take a disk and:
1. convert the disk into vhd
2. create a deployment with a custom secureboot certificate
3. upload the vhd to Azure
4. create an Azure image gallery with that disk

Upload options (define them as variable):
AZURE_RESOURCE_GROUP:       mandatory - az resource group where to create the gallery
AZURE_REGION:               optional  - az region where to create the gallery. Default: eastus
IMAGE_GALLERY_NAME:         optional  - az gallery name. Default: my_gallery
IMAGE_DEFINITION_NAME:      optional  - az image definition name. Default: podvm-image
IMAGE_DEFINITION_PUBLISHER: optional  - az image definition publisher. Default: dm-verity
IMAGE_DEFINITION_OFFER:     optional  - az image definition offer. Default: MyPublisher
IMAGE_DEFINITION_SKU:       optional  - az image definition sku. Default: My-PodVM
IMAGE_VERSION:              optional  - az image version. Default: My-PodVM
IMAGE_BLOB_NAME:            optional  - az image storage blob name. Default: 1.0.0
AZURE_SB_TEMPLATE:          optional  - az deployment template to automatically fill. Default: ./azure/azure-sb-template.json
AZURE_DEPLOYMENT_NAME:      optional  - az deployment name. Default: my-deployment
UPLOAD_SCRIPT_LOCATION:     optional  - location of the upload-azure.sh script. Default: ./azure/upload-azure.sh
```
The script will print as last line the full Azure Image ID.