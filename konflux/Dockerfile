FROM quay.io/redhat-user-workloads/ose-osc-tenant/osc-podvm-payload@sha256:6697fb29213667fa18b4b5dbdb0fb8f9123f8bd16046034741b7bc51518fc541 as payload

FROM registry.redhat.io/ubi9/ubi-init:9.8-1788333773

RUN subscription-manager register --org "$(cat /activation-key/org)" --activationkey "$(cat /activation-key/activationkey)"

RUN dnf install -y \
cpio systemd-ukify jq openssl qemu-img libguestfs guestfs-tools libguestfs-tools virt-install qemu-kvm edk2-ovmf nc

COPY qemu.conf /etc/libvirt/qemu.conf

COPY --from=payload /podvm-binaries.tar.gz /payload/
COPY --from=payload /pause-bundle.tar.gz /payload/

# to make virt-customize work
ENV LIBGUESTFS_BACKEND=direct

