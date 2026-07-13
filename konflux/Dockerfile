FROM quay.io/redhat-user-workloads/ose-osc-tenant/osc-podvm-payload@sha256:d47197560b46c79f85721f2ad701516e0d3de2d32e322d2cb7ad97464377b73c as payload

FROM registry.redhat.io/ubi9/ubi-init:9.8-1781514776

RUN subscription-manager register --org "$(cat /activation-key/org)" --activationkey "$(cat /activation-key/activationkey)"

RUN dnf install -y \
cpio systemd-ukify jq openssl qemu-img libguestfs guestfs-tools libguestfs-tools virt-install qemu-kvm edk2-ovmf nc

COPY qemu.conf /etc/libvirt/qemu.conf

COPY --from=payload /podvm-binaries.tar.gz /payload/
COPY --from=payload /pause-bundle.tar.gz /payload/

# to make virt-customize work
ENV LIBGUESTFS_BACKEND=direct

