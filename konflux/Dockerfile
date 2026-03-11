FROM quay.io/redhat-user-workloads/ose-osc-tenant/osc-podvm-payload-v1-11@sha256:49054c05d3a1aff308fcf9decaa6652bdf6d33eb7494de0af416c8355f454e46 as payload

FROM registry.redhat.io/ubi9/ubi-init@sha256:7380cfd989f8169417350e00c1c3558cae01cb4ef367927f91fd5d43470e159e

RUN subscription-manager register --org "$(cat /activation-key/org)" --activationkey "$(cat /activation-key/activationkey)"

RUN dnf install -y \
cpio systemd-ukify jq openssl qemu-img libguestfs guestfs-tools libguestfs-tools virt-install qemu-kvm edk2-ovmf nc

COPY qemu.conf /etc/libvirt/qemu.conf

COPY --from=payload /podvm-binaries.tar.gz /payload/
COPY --from=payload /pause-bundle.tar.gz /payload/

# to make virt-customize work
ENV LIBGUESTFS_BACKEND=direct

