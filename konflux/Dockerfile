FROM quay.io/redhat-user-workloads/ose-osc-tenant/osc-podvm-payload@sha256:21dc5e86ee3832e39df113e629578d9e40416f1c6278930d3d6fedefd46b805f as payload

FROM registry.redhat.io/ubi9/ubi-init:9.8-1791290738

RUN subscription-manager register --org "$(cat /activation-key/org)" --activationkey "$(cat /activation-key/activationkey)"

RUN dnf install -y \
cpio systemd-ukify jq openssl qemu-img libguestfs guestfs-tools libguestfs-tools virt-install qemu-kvm edk2-ovmf nc

COPY qemu.conf /etc/libvirt/qemu.conf

COPY --from=payload /podvm-binaries.tar.gz /payload/
COPY --from=payload /pause-bundle.tar.gz /payload/

# to make virt-customize work
ENV LIBGUESTFS_BACKEND=direct

