FROM quay.io/redhat-user-workloads/ose-osc-tenant/osc-podvm-payload@sha256:776a00a7525e7aab504bf9d1dfc6b3e85d5111df57c759e3b4cd303e76a760e0 as payload

FROM registry.redhat.io/ubi9/ubi-init@sha256:d200f0700fbd06864ab963e5c24b06b1d4db866db66c5fff407124ed1c209230

RUN subscription-manager register --org "$(cat /activation-key/org)" --activationkey "$(cat /activation-key/activationkey)"

RUN dnf install -y \
cpio systemd-ukify jq openssl qemu-img libguestfs guestfs-tools libguestfs-tools virt-install qemu-kvm edk2-ovmf nc

COPY qemu.conf /etc/libvirt/qemu.conf

COPY --from=payload /podvm-binaries.tar.gz /payload/
COPY --from=payload /pause-bundle.tar.gz /payload/

# to make virt-customize work
ENV LIBGUESTFS_BACKEND=direct

