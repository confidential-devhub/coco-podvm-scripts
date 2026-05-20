FROM quay.io/redhat-user-workloads/ose-osc-tenant/osc-podvm-payload@sha256:6eb774f0aa7e1c916c27a65ca09e17f02fcae5a6adfd5bbd060d87ba3e0c3551 as payload

FROM registry.redhat.io/ubi9/ubi-init@sha256:1d9b8da63de5fc7bb42add5274792e7f1489f71a5d8d0f137d8d13c112d98b1d

RUN subscription-manager register --org "$(cat /activation-key/org)" --activationkey "$(cat /activation-key/activationkey)"

RUN dnf install -y \
cpio systemd-ukify jq openssl qemu-img libguestfs guestfs-tools libguestfs-tools virt-install qemu-kvm edk2-ovmf nc

COPY qemu.conf /etc/libvirt/qemu.conf

COPY --from=payload /podvm-binaries.tar.gz /payload/
COPY --from=payload /pause-bundle.tar.gz /payload/

# to make virt-customize work
ENV LIBGUESTFS_BACKEND=direct

