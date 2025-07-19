FROM registry.redhat.io/ubi9/ubi-init@sha256:4b29d34b9e310f1b8fa93bb2c727a1efa43328f5d647d50ebefb82cc1c4197ff

RUN subscription-manager register --org "$(cat /activation-key/org)" --activationkey "$(cat /activation-key/activationkey)"

RUN dnf install -y \
cpio systemd-ukify jq openssl qemu-img libguestfs guestfs-tools libguestfs-tools virt-install

COPY qemu.conf /etc/libvirt/qemu.conf

# to make virt-customize work
ENV LIBGUESTFS_BACKEND=direct

