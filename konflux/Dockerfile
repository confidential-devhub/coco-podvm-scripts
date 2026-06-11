FROM quay.io/redhat-user-workloads/ose-osc-tenant/osc-podvm-payload-v1-12@sha256:3568b3cdc50a1b8366b36a404576dca0de15922a1927cabb2bd9b664de921a66 as payload

FROM registry.redhat.io/ubi9/ubi-init@sha256:4c802a7e42aaa499f8012a82393a34f960083c249e74dabd05d53b2ece1f6692

RUN subscription-manager register --org "$(cat /activation-key/org)" --activationkey "$(cat /activation-key/activationkey)"

RUN dnf install -y \
cpio systemd-ukify jq openssl qemu-img libguestfs guestfs-tools libguestfs-tools virt-install qemu-kvm edk2-ovmf nc

COPY qemu.conf /etc/libvirt/qemu.conf

COPY --from=payload /podvm-binaries.tar.gz /payload/
COPY --from=payload /pause-bundle.tar.gz /payload/

# to make virt-customize work
ENV LIBGUESTFS_BACKEND=direct

