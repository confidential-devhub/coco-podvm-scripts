FROM quay.io/redhat-user-workloads/ose-osc-tenant/osc-podvm-payload@sha256:58cbc89d71dde35f699ac9209db8a6069df349cbaa706dfdde91d1872a92728e as payload

FROM registry.redhat.io/ubi9/ubi-init@sha256:c7f5270ee939c43bb113f0b5074529bf3d25153a34ff1ffabcc5d26c56edcbaf

RUN subscription-manager register --org "$(cat /activation-key/org)" --activationkey "$(cat /activation-key/activationkey)"

RUN dnf install -y \
cpio systemd-ukify jq openssl qemu-img libguestfs guestfs-tools libguestfs-tools virt-install qemu-kvm edk2-ovmf nc

COPY qemu.conf /etc/libvirt/qemu.conf

COPY --from=payload /podvm-binaries.tar.gz /payload/
COPY --from=payload /pause-bundle.tar.gz /payload/

# to make virt-customize work
ENV LIBGUESTFS_BACKEND=direct

