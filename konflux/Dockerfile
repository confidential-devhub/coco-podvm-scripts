FROM registry.redhat.io/ubi9/ubi-init@sha256:7df2695f86178b20ab5501fa3f746bd42f79caaa53f857928b87dfedbd4674ca

RUN subscription-manager register --org "$(cat /activation-key/org)" --activationkey "$(cat /activation-key/activationkey)"

RUN dnf install -y \
cpio systemd-ukify jq openssl qemu-img libguestfs guestfs-tools libguestfs-tools virt-install qemu-kvm edk2-ovmf nc

COPY qemu.conf /etc/libvirt/qemu.conf

# to make virt-customize work
ENV LIBGUESTFS_BACKEND=direct

