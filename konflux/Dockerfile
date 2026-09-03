FROM quay.io/redhat-user-workloads/ose-osc-tenant/osc-podvm-payload@sha256:235c193fa133fb06c9f4300bcd4d72dfe5863c9fe8725c0c6a80a3b6a3c27e51 as payload

FROM registry.redhat.io/ubi9/ubi-init:9.8-1781514776

RUN subscription-manager register --org "$(cat /activation-key/org)" --activationkey "$(cat /activation-key/activationkey)"

RUN dnf install -y \
cpio systemd-ukify jq openssl qemu-img libguestfs guestfs-tools libguestfs-tools virt-install qemu-kvm edk2-ovmf nc

COPY qemu.conf /etc/libvirt/qemu.conf

COPY --from=payload /podvm-binaries.tar.gz /payload/
COPY --from=payload /pause-bundle.tar.gz /payload/

# to make virt-customize work
ENV LIBGUESTFS_BACKEND=direct

