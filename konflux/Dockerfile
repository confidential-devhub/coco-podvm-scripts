FROM quay.io/redhat-user-workloads/ose-osc-tenant/osc-podvm-payload@sha256:7317c2d8c0ac8e542e39d695851c4add301593d2b52af80c77fd4f996efbe2b8 as payload

FROM registry.redhat.io/ubi9/ubi-init@sha256:6632d5c118d796e64d8c3080e424d92c1c1302d51ff1057f13c757d9a2d81ea8

RUN subscription-manager register --org "$(cat /activation-key/org)" --activationkey "$(cat /activation-key/activationkey)"

RUN dnf install -y \
cpio systemd-ukify jq openssl qemu-img libguestfs guestfs-tools libguestfs-tools virt-install qemu-kvm edk2-ovmf nc

COPY qemu.conf /etc/libvirt/qemu.conf

COPY --from=payload /podvm-binaries.tar.gz /payload/
COPY --from=payload /pause-bundle.tar.gz /payload/

# to make virt-customize work
ENV LIBGUESTFS_BACKEND=direct

