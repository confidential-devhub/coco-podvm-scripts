FROM quay.io/redhat-user-workloads/ose-osc-tenant/osc-podvm-payload@sha256:5c2a952af1744423f522a4c102eb1523b1034a4c165702033af7a2f728d52240 as payload

FROM registry.redhat.io/ubi9/ubi-init@sha256:0e363b4962742275e45d23621014890c7f023a41c84f776d10fa9423536ec21b

RUN subscription-manager register --org "$(cat /activation-key/org)" --activationkey "$(cat /activation-key/activationkey)"

RUN dnf install -y \
cpio systemd-ukify jq openssl qemu-img libguestfs guestfs-tools libguestfs-tools virt-install qemu-kvm edk2-ovmf nc

COPY qemu.conf /etc/libvirt/qemu.conf

COPY --from=payload /podvm-binaries.tar.gz /payload/
COPY --from=payload /pause-bundle.tar.gz /payload/

# to make virt-customize work
ENV LIBGUESTFS_BACKEND=direct

