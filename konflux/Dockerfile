FROM quay.io/redhat-user-workloads/ose-osc-tenant/osc-podvm-payload@sha256:de675e7a6775972d9ac755259c4fd6964e10a2ac3e0faef0bdd69317ecd380d7 as payload

FROM registry.redhat.io/ubi9/ubi-init@sha256:c7f5270ee939c43bb113f0b5074529bf3d25153a34ff1ffabcc5d26c56edcbaf

RUN subscription-manager register --org "$(cat /activation-key/org)" --activationkey "$(cat /activation-key/activationkey)"

RUN dnf install -y \
cpio systemd-ukify jq openssl qemu-img libguestfs guestfs-tools libguestfs-tools virt-install qemu-kvm edk2-ovmf nc

COPY qemu.conf /etc/libvirt/qemu.conf

COPY --from=payload /podvm-binaries.tar.gz /payload/
COPY --from=payload /pause-bundle.tar.gz /payload/

# to make virt-customize work
ENV LIBGUESTFS_BACKEND=direct

