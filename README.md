# How to create a dm-verity image via container

1. Download official RHEL ISO and build a CVM with `helpers/rhel10-dm-root.ks`:

Change the QCOW2_Name everytime you rebuild it. 
Install libvirt and place the downloaded rhel iso image in the given path of ISO_PATH.

```
ISO_PATH=/var/lib/libvirt/images/rhel-10.1-x86_64-dvd.iso
KS_LOCATION=helpers/rhel10-dm-root.ks
QCOW2_NAME=trial-image-21

virt-install --virt-type kvm --os-variant rhel10.0 --arch x86_64   --boot uefi,firmware.feature0.name=secure-boot,firmware.feature0.enabled=no,firmware.feature1.name=enrolled-keys,firmware.feature1.enabled=no   --name $QCOW2_NAME --memory 8192   --location $ISO_PATH   --disk bus=scsi,size=15   --initrd-inject=$KS_LOCATION   --nographics   --extra-args "console=ttyS0 inst.ks=file:/rhel10-dm-root.ks"   --transient --debug

```

Image will be stored in `/var/lib/libvirt/images/$QCOW2_NAME.qcow2`


2. Run the automation script from root directory:

```
export ACTIVATION_KEY=<your_activation_key>
export ORG_ID=<your_org_id>
export ROOT_PASSWORD=12345
./example_run.sh <Image_Path_From_Step1>
```
The above file path is :- `/var/lib/libvirt/images/$QCOW2_NAME.qcow2`

3. Convert the image to a container image:

```
cd helpers/build-container/
cp /var/lib/libvirt/images/$QCOW2_NAME.qcow2 .
podman build -t coco-podvm --build-arg PODVM_IMAGE_SRC=$QCOW2_NAME.qcow2 .
```

Or use the build script:

```
cd helpers/build-container/
./build.sh <qcow2-image_path>
```

4. Push to your registry:

```
podman tag localhost/coco-podvm:latest <your_repo_image_tag>
podman push <your_repo_image_tag>
```

As a result, the input image will contain coco-components and be dm-verity protected.

After this we need to make changes to our main repo containing the ARO cluster details and the yaml files. Follow from STEP 5 of Debug_Image_Creation.md file in the other PeerPods repo.


5. Optionally, upload yourself the image on Azure image gallery using `azure/upload-azure.sh`. In order to use that script, define the following variables (usage message available also by running `azure/upload-azure.sh help`):

```
Usage: azure/upload-azure.sh <INPUT_IMAGE> [<DER_CERTIFICATE>]
Usage: azure/upload-azure.sh help
Usage: azure/upload-azure.sh <INPUT_IMAGE> [<DER_CERTIFICATE>]
Usage: azure/upload-azure.sh help

The purpose of this script is to take a disk and:
1. convert the disk into vhd
2. if DER_CERTIFICATE is defined, create a deployment with a custom secureboot certificate
3. upload the vhd to Azure
4. create an Azure image gallery with that disk

Upload options (define them as variable):
AZURE_RESOURCE_GROUP:       mandatory - az resource group where to create the gallery
AZURE_REGION:               optional  - az region where to create the gallery. Default: eastus
IMAGE_GALLERY_NAME:         optional  - az gallery name. Default: my_gallery
IMAGE_DEFINITION_NAME:      optional  - az image definition name. Default: podvm-image
IMAGE_DEFINITION_PUBLISHER: optional  - az image definition publisher. Default: MyPublisher
IMAGE_DEFINITION_OFFER:     optional  - az image definition offer. Default: My-PodVM
IMAGE_DEFINITION_SKU:       optional  - az image definition sku. Default: My-PodVM
IMAGE_VERSION:              optional  - az image version. Default: 1.0.0
IMAGE_BLOB_NAME:            optional  - az image storage blob name. Default: dm-verity
AZURE_SB_TEMPLATE:          optional  - az deployment template to automatically fill. Default: ./azure/azure-sb-template.json
AZURE_DEPLOYMENT_NAME:      optional  - az deployment name. Default: my-deployment
UPLOAD_SCRIPT_LOCATION:     optional  - location of the upload-azure.sh script. Default: ./azure/upload-azure.sh
```
The script will print as last line the full Azure Image ID.

---

## Additional Configuration Options

The `scripts/create-verity-podvm.sh` script (used by `example_run.sh`) supports these optional environment variables:

The purpose of this script is to take a disk and:
1. convert the disk into vhd
2. if DER_CERTIFICATE is defined, create a deployment with a custom secureboot certificate
3. upload the vhd to Azure
4. create an Azure image gallery with that disk

Upload options (define them as variable):
AZURE_RESOURCE_GROUP:       mandatory - az resource group where to create the gallery
AZURE_REGION:               optional  - az region where to create the gallery. Default: eastus
IMAGE_GALLERY_NAME:         optional  - az gallery name. Default: my_gallery
IMAGE_DEFINITION_NAME:      optional  - az image definition name. Default: podvm-image
IMAGE_DEFINITION_PUBLISHER: optional  - az image definition publisher. Default: MyPublisher
IMAGE_DEFINITION_OFFER:     optional  - az image definition offer. Default: My-PodVM
IMAGE_DEFINITION_SKU:       optional  - az image definition sku. Default: My-PodVM
IMAGE_VERSION:              optional  - az image version. Default: 1.0.0
IMAGE_BLOB_NAME:            optional  - az image storage blob name. Default: dm-verity
AZURE_SB_TEMPLATE:          optional  - az deployment template to automatically fill. Default: ./azure/azure-sb-template.json
AZURE_DEPLOYMENT_NAME:      optional  - az deployment name. Default: my-deployment
UPLOAD_SCRIPT_LOCATION:     optional  - location of the upload-azure.sh script. Default: ./azure/upload-azure.sh
```
The script will print as last line the full Azure Image ID.

---

## Additional Configuration Options

The `scripts/create-verity-podvm.sh` script (used by `example_run.sh`) supports these optional environment variables:

```
Usage: ./create-verity-podvm.sh <INPUT_IMAGE>
Usage: ./create-verity-podvm.sh help

The purpose of this script is to take a disk and:
1. create new certificates for the new image secureboot db, if not provided
2. install coco guest components in the disk
3. call verity script to verity protect the root disk

Options (define them as variable):
IMAGE_CERTIFICATE_DER:      optional  - certificate in DER format to upload in the gallery. Default: generate a new one
IMAGE_CERTIFICATE_PEM:      optional  - certificate in PEM format to upload in the gallery. Default: generate a new one
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
PODVM_BINARY:               optional   - registry containing podvm binary. Default: $PODVM_BINARY_DEF
PODVM_BINARY_LOCATION:      optional   - location in container containing podvm binary. Default: /podvm-binaries.tar.gz
PAUSE_BUNDLE:               optional   - registry containing pause bundle. Default: $PAUSE_BUNDLE_DEF
PAUSE_BUNDLE_LOCATION:      optional   - location in container containing pause bundle. Default: /pause-bundle.tar.gz
ROOT_PASSWORD:              optional   - set root's password. Default: disabled

```

## Optional: Generate certificates for secureboot

If not available, generate private key, PEM and DER certificates using `helpers/create-certs.sh`. This is only needed if secureboot has to be enabled.
## Optional: Generate certificates for secureboot

If not available, generate private key, PEM and DER certificates using `helpers/create-certs.sh`. This is only needed if secureboot has to be enabled.
```
Usage: ./helpers/create-certs.sh <OUTPUT_FOLDER>
Usage: ./helpers/create-certs.sh help
Usage: ./helpers/create-certs.sh <OUTPUT_FOLDER>
Usage: ./helpers/create-certs.sh help

The purpose of this script is to create a private key and public DER and PEM certs.
The only input command is to specify where to store the key and certs.

Options (define them as variable):
SB_CERT_NAME:  optional  - name of the secureboot certificate added into the gallery. Default: My custom certificate

