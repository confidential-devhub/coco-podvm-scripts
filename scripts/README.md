# How to create a dm-verity image

1. Define the following vars (usage message available also with `create-verity-podvm.sh help`)
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

2. Run `create-verity-podvm.sh` that internally calls `coco/coco-components.sh` and `verity/verity.sh`

```
RHEL_QCOW2=rhel_9.6-x86_64-cvm.qcow2

create-verity-podvm.sh $RHEL_QCOW2
```
As a result, the input image will contain coco-components and be dm-verity protected.
