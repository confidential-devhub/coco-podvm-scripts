FROM quay.io/redhat-user-workloads/ose-osc-tenant/osc-podvm-payload@sha256:776a00a7525e7aab504bf9d1dfc6b3e85d5111df57c759e3b4cd303e76a760e0 as payload

FROM registry.redhat.io/ubi9/ubi-init@sha256:3a3a6683b50731c5a713aa53ed370e43ce00b05a4587b82258e61d7985f65389

RUN subscription-manager register --org "$(cat /activation-key/org)" --activationkey "$(cat /activation-key/activationkey)"

RUN dnf install -y \
cpio systemd-ukify jq openssl qemu-img libguestfs guestfs-tools libguestfs-tools virt-install qemu-kvm edk2-ovmf nc

COPY qemu.conf /etc/libvirt/qemu.conf

COPY --from=payload /podvm-binaries.tar.gz /payload/
COPY --from=payload /pause-bundle.tar.gz /payload/

# to make virt-customize work
ENV LIBGUESTFS_BACKEND=direct

