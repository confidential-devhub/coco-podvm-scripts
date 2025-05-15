#! /bin/bash

QCOW2=~/.local/share/libvirt/images/rhel9.5-created-ks.qcow2
IMAGE_CERTIFICATE_PEM=/home/eesposit/openshift/coco-podvm-scripts/scripts/certs/public_key.pem
IMAGE_PRIVATE_KEY=/home/eesposit/openshift/coco-podvm-scripts/scripts/certs/private.key

sudo podman build coco-podvm .

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

