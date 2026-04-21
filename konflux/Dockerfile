FROM quay.io/redhat-user-workloads/ose-osc-tenant/osc-podvm-payload@sha256:5c2a952af1744423f522a4c102eb1523b1034a4c165702033af7a2f728d52240 as payload

FROM registry.redhat.io/ubi9/ubi-init@sha256:78a0a01dac2e33ffd869673b52f925cac9da6bfd4ba868622adefa3837c39831

RUN subscription-manager register --org "$(cat /activation-key/org)" --activationkey "$(cat /activation-key/activationkey)"

RUN dnf install -y \
cpio systemd-ukify jq openssl qemu-img libguestfs guestfs-tools libguestfs-tools virt-install qemu-kvm edk2-ovmf nc

COPY qemu.conf /etc/libvirt/qemu.conf

COPY --from=payload /podvm-binaries.tar.gz /payload/
COPY --from=payload /pause-bundle.tar.gz /payload/

# to make virt-customize work
ENV LIBGUESTFS_BACKEND=direct

