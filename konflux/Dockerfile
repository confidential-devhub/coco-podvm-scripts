FROM quay.io/redhat-user-workloads/ose-osc-tenant/osc-podvm-payload@sha256:fec2a53170336125bcd5b8f11c3420871cf9f2a117b679a62aadf3292335c9a8 as payload

FROM registry.redhat.io/ubi9/ubi-init@sha256:2e61e717ac1f78d4d6722b69b6064726167fc40e937d6e651cff136b7ab6051e

RUN subscription-manager register --org "$(cat /activation-key/org)" --activationkey "$(cat /activation-key/activationkey)"

RUN dnf install -y \
cpio systemd-ukify jq openssl qemu-img libguestfs guestfs-tools libguestfs-tools virt-install qemu-kvm edk2-ovmf nc

COPY qemu.conf /etc/libvirt/qemu.conf

COPY --from=payload /podvm-binaries.tar.gz /payload/
COPY --from=payload /pause-bundle.tar.gz /payload/

# to make virt-customize work
ENV LIBGUESTFS_BACKEND=direct

