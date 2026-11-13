FROM quay.io/redhat-user-workloads/ose-osc-tenant/osc-podvm-payload-v1-13@sha256:dc20703ca0d261f60ed7c8e71a7ee3510c8cfb439e3cf2747583ac2d17417ba5 as payload

FROM registry.redhat.io/ubi9/ubi-init:9.9-1794500054

RUN subscription-manager register --org "$(cat /activation-key/org)" --activationkey "$(cat /activation-key/activationkey)"

RUN dnf install -y \
cpio systemd-ukify jq openssl qemu-img libguestfs guestfs-tools libguestfs-tools virt-install qemu-kvm edk2-ovmf nc

COPY qemu.conf /etc/libvirt/qemu.conf

COPY --from=payload /podvm-binaries.tar.gz /payload/
COPY --from=payload /pause-bundle.tar.gz /payload/

# to make virt-customize work
ENV LIBGUESTFS_BACKEND=direct

