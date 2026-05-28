FROM quay.io/redhat-user-workloads/ose-osc-tenant/osc-podvm-payload@sha256:e07098d4910a45d29571215346b50ad318141e5d3f3398326428254784fbeb7e as payload

FROM registry.redhat.io/ubi9/ubi-init@sha256:2a40900a2ac68e14888509b66782f2d321427153fdd9e056fa187e1138f5b548

RUN subscription-manager register --org "$(cat /activation-key/org)" --activationkey "$(cat /activation-key/activationkey)"

RUN dnf install -y \
cpio systemd-ukify jq openssl qemu-img libguestfs guestfs-tools libguestfs-tools virt-install qemu-kvm edk2-ovmf nc

COPY qemu.conf /etc/libvirt/qemu.conf

COPY --from=payload /podvm-binaries.tar.gz /payload/
COPY --from=payload /pause-bundle.tar.gz /payload/

# to make virt-customize work
ENV LIBGUESTFS_BACKEND=direct

