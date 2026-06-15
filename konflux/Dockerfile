FROM quay.io/redhat-user-workloads/ose-osc-tenant/osc-podvm-payload@sha256:911df63d29774d519271597888e30f093a42a6c4a56ac62e939199ecdbec47d2 as payload

FROM registry.redhat.io/ubi9/ubi-init@sha256:01b209e7b1e22d098de897d853acdada8a397fb20acf17cc3e076decc6bb17f8

RUN subscription-manager register --org "$(cat /activation-key/org)" --activationkey "$(cat /activation-key/activationkey)"

RUN dnf install -y \
cpio systemd-ukify jq openssl qemu-img libguestfs guestfs-tools libguestfs-tools virt-install qemu-kvm edk2-ovmf nc

COPY qemu.conf /etc/libvirt/qemu.conf

COPY --from=payload /podvm-binaries.tar.gz /payload/
COPY --from=payload /pause-bundle.tar.gz /payload/

# to make virt-customize work
ENV LIBGUESTFS_BACKEND=direct

