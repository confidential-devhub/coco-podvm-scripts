FROM registry.redhat.io/ubi9/ubi-init@sha256:3b2221f1913494b950bd0b6122553c7278af5d261196a812c71d6819d764b24d

RUN subscription-manager register --org "$(cat /activation-key/org)" --activationkey "$(cat /activation-key/activationkey)"

RUN dnf install -y \
cpio systemd-ukify jq openssl qemu-img libguestfs guestfs-tools libguestfs-tools virt-install

COPY qemu.conf /etc/libvirt/qemu.conf

# to make virt-customize work
ENV LIBGUESTFS_BACKEND=direct

