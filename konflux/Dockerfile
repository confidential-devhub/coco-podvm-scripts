FROM quay.io/redhat-user-workloads/ose-osc-tenant/osc-podvm-payload@sha256:fec2a53170336125bcd5b8f11c3420871cf9f2a117b679a62aadf3292335c9a8 as payload

FROM registry.redhat.io/ubi9/ubi-init@sha256:2d367667ef6e3736a962089552717729ff7a62df1d0c4573eebbbad8a1671105

RUN subscription-manager register --org "$(cat /activation-key/org)" --activationkey "$(cat /activation-key/activationkey)"

RUN dnf install -y \
cpio systemd-ukify jq openssl qemu-img libguestfs guestfs-tools libguestfs-tools virt-install qemu-kvm edk2-ovmf nc

COPY qemu.conf /etc/libvirt/qemu.conf

COPY --from=payload /podvm-binaries.tar.gz /payload/
COPY --from=payload /pause-bundle.tar.gz /payload/

# to make virt-customize work
ENV LIBGUESTFS_BACKEND=direct

