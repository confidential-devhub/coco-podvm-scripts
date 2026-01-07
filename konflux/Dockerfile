FROM quay.io/redhat-user-workloads/ose-osc-tenant/osc-podvm-payload@sha256:c02b94e504810e546cb72b0a92a4b5ca3ae3fe14cff55a6d404421e301d73691 as payload

FROM registry.redhat.io/ubi9/ubi-init@sha256:14543ea72c42f5db5d8815b7daea12e914c04f71b3c165a7a58d3bcbb3d79c3d

RUN subscription-manager register --org "$(cat /activation-key/org)" --activationkey "$(cat /activation-key/activationkey)"

RUN dnf install -y \
cpio systemd-ukify jq openssl qemu-img libguestfs guestfs-tools libguestfs-tools virt-install qemu-kvm edk2-ovmf nc

COPY qemu.conf /etc/libvirt/qemu.conf

COPY --from=payload /podvm-binaries.tar.gz /payload/
COPY --from=payload /pause-bundle.tar.gz /payload/

# to make virt-customize work
ENV LIBGUESTFS_BACKEND=direct

