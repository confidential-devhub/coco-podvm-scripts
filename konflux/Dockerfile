FROM quay.io/redhat-user-workloads/ose-osc-tenant/osc-podvm-payload-v1-13@sha256:d85b53ff1143ea3fd0eafe9b223ffa47ee72dcd5af27cf3e3006e441297f1489 as payload

FROM registry.redhat.io/ubi9/ubi-init:9.8-1781514776

RUN subscription-manager register --org "$(cat /activation-key/org)" --activationkey "$(cat /activation-key/activationkey)"

RUN dnf install -y \
cpio systemd-ukify jq openssl qemu-img libguestfs guestfs-tools libguestfs-tools virt-install qemu-kvm edk2-ovmf nc

COPY qemu.conf /etc/libvirt/qemu.conf

COPY --from=payload /podvm-binaries.tar.gz /payload/
COPY --from=payload /pause-bundle.tar.gz /payload/

# to make virt-customize work
ENV LIBGUESTFS_BACKEND=direct

