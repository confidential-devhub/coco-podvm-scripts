FROM quay.io/redhat-user-workloads/ose-osc-tenant/osc-podvm-payload-v1-13@sha256:f1402ed51e29970ed4e67604a9b9240ce7dd4b8d04a1fa5c65728135e7328323 as payload

FROM registry.redhat.io/ubi9/ubi-init:9.8-1790153988

RUN subscription-manager register --org "$(cat /activation-key/org)" --activationkey "$(cat /activation-key/activationkey)"

RUN dnf install -y \
cpio systemd-ukify jq openssl qemu-img libguestfs guestfs-tools libguestfs-tools virt-install qemu-kvm edk2-ovmf nc

COPY qemu.conf /etc/libvirt/qemu.conf

COPY --from=payload /podvm-binaries.tar.gz /payload/
COPY --from=payload /pause-bundle.tar.gz /payload/

# to make virt-customize work
ENV LIBGUESTFS_BACKEND=direct

