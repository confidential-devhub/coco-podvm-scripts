FROM quay.io/redhat-user-workloads/ose-osc-tenant/osc-podvm-payload@sha256:ffcea670c5abb0acdb16941e71a6559353807c1fcef250e1f8ad5eeb592abbd5 as payload

FROM registry.redhat.io/ubi9/ubi-init:9.8-1789048530

RUN subscription-manager register --org "$(cat /activation-key/org)" --activationkey "$(cat /activation-key/activationkey)"

RUN dnf install -y \
cpio systemd-ukify jq openssl qemu-img libguestfs guestfs-tools libguestfs-tools virt-install qemu-kvm edk2-ovmf nc

COPY qemu.conf /etc/libvirt/qemu.conf

COPY --from=payload /podvm-binaries.tar.gz /payload/
COPY --from=payload /pause-bundle.tar.gz /payload/

# to make virt-customize work
ENV LIBGUESTFS_BACKEND=direct

