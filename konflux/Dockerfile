FROM quay.io/redhat-user-workloads/ose-osc-tenant/osc-podvm-payload@sha256:ac2cad273055786fda57fea8beeb2e7b6a0f24f55b711557e7bae8e916886faf as payload

FROM registry.redhat.io/ubi9/ubi-init@sha256:d200f0700fbd06864ab963e5c24b06b1d4db866db66c5fff407124ed1c209230

RUN subscription-manager register --org "$(cat /activation-key/org)" --activationkey "$(cat /activation-key/activationkey)"

RUN dnf install -y \
cpio systemd-ukify jq openssl qemu-img libguestfs guestfs-tools libguestfs-tools virt-install qemu-kvm edk2-ovmf nc

COPY qemu.conf /etc/libvirt/qemu.conf

COPY --from=payload /podvm-binaries.tar.gz /payload/
COPY --from=payload /pause-bundle.tar.gz /payload/

# to make virt-customize work
ENV LIBGUESTFS_BACKEND=direct

