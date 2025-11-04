#! /bin/bash

QCOW2=${1:-${QCOW2:-~/.local/share/libvirt/images/rhel10.0-created-ks.qcow2}}
IMAGE_CERTIFICATE_PEM=$2
IMAGE_PRIVATE_KEY=$3

[[ -f $QCOW2 ]] || \
    { printf "One or more required files are missing:\n\tQCOW2=$QCOW2\n "; exit 1; }

[[ -n "${ACTIVATION_KEY}" && -n "${ORG_ID}" ]] && subscription=" --build-arg ORG_ID=${ORG_ID} --build-arg ACTIVATION_KEY=${ACTIVATION_KEY} "

if [[ -n "${IMAGE_CERTIFICATE_PEM}" && -n "${IMAGE_PRIVATE_KEY}" ]]; then
    CERT_OPTIONS="-v $IMAGE_CERTIFICATE_PEM:/public.pem:ro,Z -v $IMAGE_PRIVATE_KEY:/private.key:ro,Z"
fi

sudo podman build -t coco-podvm \
    ${subscription} \
    -f Dockerfile . || printf "\n\n!!! Faild to build coco-podvm, will used cached image if exist !!!\n"

[[ -n "$ROOT_PASSWORD" ]] && run_extras+=" -e ROOT_PASSWORD=$ROOT_PASSWORD "
[[ -n "$AUTHFILE" ]] && run_extras+=" -v ${AUTHFILE}:/authfile:ro,z "

sudo podman run --rm \
    --privileged \
    -v $QCOW2:/disk.qcow2 \
    $CERT_OPTIONS \
    -v /lib/modules:/lib/modules:ro,Z \
    --env ORG_ID=${ORG_ID} --env ACTIVATION_KEY=${ACTIVATION_KEY} \
    --user 0 \
    --security-opt=apparmor=unconfined \
    --security-opt=seccomp=unconfined \
    --mount type=bind,source=/dev,target=/dev \
    --mount type=bind,source=/run/udev,target=/run/udev \
    $run_extras \
    localhost/coco-podvm
