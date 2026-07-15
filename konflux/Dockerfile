FROM quay.io/redhat-user-workloads/ose-osc-tenant/osc-podvm-payload-v1-12@sha256:6a51a51d7b8c6700f3ad01bf223aa5e898449336f2d2519c80b8c610295b8d1a as payload

FROM registry.redhat.io/ubi9/ubi-init@sha256:610a9f12a576fb8987a2a9faa362faa12dfb4f187b144945076a366f70db29b4

RUN subscription-manager register --org "$(cat /activation-key/org)" --activationkey "$(cat /activation-key/activationkey)"

RUN dnf install -y \
cpio systemd-ukify jq openssl qemu-img libguestfs guestfs-tools libguestfs-tools virt-install qemu-kvm edk2-ovmf nc

COPY qemu.conf /etc/libvirt/qemu.conf

COPY --from=payload /podvm-binaries.tar.gz /payload/
COPY --from=payload /pause-bundle.tar.gz /payload/

# to make virt-customize work
ENV LIBGUESTFS_BACKEND=direct

