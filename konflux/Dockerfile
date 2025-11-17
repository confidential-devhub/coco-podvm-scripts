FROM quay.io/redhat-user-workloads/ose-osc-tenant/osc-podvm-payload@sha256:91070585ecf80c7872e6ef3bf26e23b4a6bb6e26b5cfb5943e116294fec21d46 as payload

FROM registry.redhat.io/ubi9/ubi-init@sha256:f522b54e25697855845c14a3b16c501e3dd5af518ca7fd6cdc81166c3a2aed51

RUN subscription-manager register --org "$(cat /activation-key/org)" --activationkey "$(cat /activation-key/activationkey)"

RUN dnf install -y \
cpio systemd-ukify jq openssl qemu-img libguestfs guestfs-tools libguestfs-tools virt-install qemu-kvm edk2-ovmf nc

COPY qemu.conf /etc/libvirt/qemu.conf

COPY --from=payload /podvm-binaries.tar.gz /payload/
COPY --from=payload /pause-bundle.tar.gz /payload/

# to make virt-customize work
ENV LIBGUESTFS_BACKEND=direct

