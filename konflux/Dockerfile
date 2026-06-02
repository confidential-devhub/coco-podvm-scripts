FROM quay.io/redhat-user-workloads/ose-osc-tenant/osc-podvm-payload@sha256:911df63d29774d519271597888e30f093a42a6c4a56ac62e939199ecdbec47d2 as payload

FROM registry.redhat.io/ubi9/ubi-init@sha256:4c802a7e42aaa499f8012a82393a34f960083c249e74dabd05d53b2ece1f6692

RUN subscription-manager register --org "$(cat /activation-key/org)" --activationkey "$(cat /activation-key/activationkey)"

RUN dnf install -y \
cpio systemd-ukify jq openssl qemu-img libguestfs guestfs-tools libguestfs-tools virt-install qemu-kvm edk2-ovmf nc

COPY qemu.conf /etc/libvirt/qemu.conf

COPY --from=payload /podvm-binaries.tar.gz /payload/
COPY --from=payload /pause-bundle.tar.gz /payload/

# to make virt-customize work
ENV LIBGUESTFS_BACKEND=direct

