#! /bin/bash

QCOW2=${1:-${QCOW2:-~/.local/share/libvirt/images/rhel9.5-created-ks.qcow2}}
IMAGE_CERTIFICATE_PEM=${2:-${IMAGE_CERTIFICATE_PEM:-$(pwd)/public_key.pem}}
IMAGE_PRIVATE_KEY=${3:-${IMAGE_PRIVATE_KEY:-$(pwd)/private.key}}

[[ -f $QCOW2 && -f $IMAGE_CERTIFICATE_PEM && -f $IMAGE_PRIVATE_KEY ]] || \
    { printf "One or more required files are missing:\n\tQCOW2=$QCOW2\n\tIMAGE_CERTIFICATE_PEM=$IMAGE_CERTIFICATE_PEM\n\tIMAGE_PRIVATE_KEY=$IMAGE_PRIVATE_KEY\n "; exit 1; }

[[ -n "${ACTIVATION_KEY}" && -n "${ORG_ID}" ]] && subscription=" --build-arg ORG_ID=${ORG_ID} --build-arg ACTIVATION_KEY=${ACTIVATION_KEY} "

sudo podman build -t coco-podvm \
    ${subscription} \
    -f Dockerfile .


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

