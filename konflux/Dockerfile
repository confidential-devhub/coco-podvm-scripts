FROM quay.io/redhat-user-workloads/ose-osc-tenant/osc-podvm-payload@sha256:c321535760ffc6f6b1529e31a3ccc56a890199076ceeb1ba24492b125ab01dcb as payload

FROM registry.redhat.io/ubi9/ubi-init@sha256:4b29d34b9e310f1b8fa93bb2c727a1efa43328f5d647d50ebefb82cc1c4197ff

RUN subscription-manager register --org "$(cat /activation-key/org)" --activationkey "$(cat /activation-key/activationkey)"

RUN dnf install -y \
cpio systemd-ukify jq openssl qemu-img libguestfs guestfs-tools libguestfs-tools virt-install qemu-kvm edk2-ovmf nc

COPY qemu.conf /etc/libvirt/qemu.conf

COPY --from=payload /podvm-binaries.tar.gz /payload/
COPY --from=payload /pause-bundle.tar.gz /payload/

# to make virt-customize work
ENV LIBGUESTFS_BACKEND=direct

