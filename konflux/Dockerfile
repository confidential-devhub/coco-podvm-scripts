FROM quay.io/redhat-user-workloads/ose-osc-tenant/osc-podvm-payload@sha256:d6e9617754ffd316d9ce573c181ae7d52a3afcef22d90a64a5aa5e0bfa67b962 as payload

FROM registry.redhat.io/ubi9/ubi-init@sha256:d6bd897e047271ccda8151b01234e58673348ce8a58b2d88a226e5df61165b3d

RUN subscription-manager register --org "$(cat /activation-key/org)" --activationkey "$(cat /activation-key/activationkey)"

RUN dnf install -y \
cpio systemd-ukify jq openssl qemu-img libguestfs guestfs-tools libguestfs-tools virt-install qemu-kvm edk2-ovmf nc

COPY qemu.conf /etc/libvirt/qemu.conf

COPY --from=payload /podvm-binaries.tar.gz /payload/
COPY --from=payload /pause-bundle.tar.gz /payload/

# to make virt-customize work
ENV LIBGUESTFS_BACKEND=direct

