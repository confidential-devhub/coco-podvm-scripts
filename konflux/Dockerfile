FROM quay.io/redhat-user-workloads/ose-osc-tenant/osc-podvm-payload@sha256:85734cfe4b1df310a768e9ed5e4962a822219de93ab2d021e7b373ac47564239 as payload

FROM registry.redhat.io/ubi9/ubi-init@sha256:96afe98d7bf8b35355abc1f3cd5ec215502ba4c75371db474c5c31137ee62ddf

RUN subscription-manager register --org "$(cat /activation-key/org)" --activationkey "$(cat /activation-key/activationkey)"

RUN dnf install -y \
cpio systemd-ukify jq openssl qemu-img libguestfs guestfs-tools libguestfs-tools virt-install qemu-kvm edk2-ovmf nc

COPY qemu.conf /etc/libvirt/qemu.conf

COPY --from=payload /podvm-binaries.tar.gz /payload/
COPY --from=payload /pause-bundle.tar.gz /payload/

# to make virt-customize work
ENV LIBGUESTFS_BACKEND=direct

