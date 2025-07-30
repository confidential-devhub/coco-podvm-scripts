FROM registry.redhat.io/ubi9/ubi-init@sha256:62f63f11ac9307061a2b2e86a4a8a7792f40de773558993f297ad3ea805ba9b8

RUN subscription-manager register --org "$(cat /activation-key/org)" --activationkey "$(cat /activation-key/activationkey)"

RUN dnf install -y \
cpio systemd-ukify jq openssl qemu-img libguestfs guestfs-tools libguestfs-tools virt-install qemu-kvm edk2-ovmf nc

COPY qemu.conf /etc/libvirt/qemu.conf

# to make virt-customize work
ENV LIBGUESTFS_BACKEND=direct

