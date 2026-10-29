FROM quay.io/redhat-user-workloads/ose-osc-tenant/osc-podvm-payload@sha256:8144a9b2619f591854ffa8a11e0799c85adbb992f161863094a4b6c50147da4e as payload

FROM registry.redhat.io/ubi9/ubi-init:9.8-1793218271

RUN subscription-manager register --org "$(cat /activation-key/org)" --activationkey "$(cat /activation-key/activationkey)"

RUN dnf install -y \
cpio systemd-ukify jq openssl qemu-img libguestfs guestfs-tools libguestfs-tools virt-install qemu-kvm edk2-ovmf nc

COPY qemu.conf /etc/libvirt/qemu.conf

COPY --from=payload /podvm-binaries.tar.gz /payload/
COPY --from=payload /pause-bundle.tar.gz /payload/

# to make virt-customize work
ENV LIBGUESTFS_BACKEND=direct

