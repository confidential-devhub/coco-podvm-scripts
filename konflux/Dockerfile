FROM quay.io/redhat-user-workloads/ose-osc-tenant/osc-podvm-payload-v1-13@sha256:29a6ac983226b5b56928622315b06dce64ddcc8fb55188a1f265d777b1eab2a6 as payload

FROM registry.redhat.io/ubi9/ubi-init:9.8-1781514776

RUN subscription-manager register --org "$(cat /activation-key/org)" --activationkey "$(cat /activation-key/activationkey)"

RUN dnf install -y \
cpio systemd-ukify jq openssl qemu-img libguestfs guestfs-tools libguestfs-tools virt-install qemu-kvm edk2-ovmf nc

COPY qemu.conf /etc/libvirt/qemu.conf

COPY --from=payload /podvm-binaries.tar.gz /payload/
COPY --from=payload /pause-bundle.tar.gz /payload/

# to make virt-customize work
ENV LIBGUESTFS_BACKEND=direct

