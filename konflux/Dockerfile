FROM quay.io/redhat-user-workloads/ose-osc-tenant/osc-podvm-payload-v1-11@sha256:f6e52efa185e59b2792ef683bff4ef59bb54fe26b5dfe598b10381340cc33d8c as payload

FROM registry.redhat.io/ubi9/ubi-init@sha256:d200f0700fbd06864ab963e5c24b06b1d4db866db66c5fff407124ed1c209230

RUN subscription-manager register --org "$(cat /activation-key/org)" --activationkey "$(cat /activation-key/activationkey)"

RUN dnf install -y \
cpio systemd-ukify jq openssl qemu-img libguestfs guestfs-tools libguestfs-tools virt-install qemu-kvm edk2-ovmf nc

COPY qemu.conf /etc/libvirt/qemu.conf

COPY --from=payload /podvm-binaries.tar.gz /payload/
COPY --from=payload /pause-bundle.tar.gz /payload/

# to make virt-customize work
ENV LIBGUESTFS_BACKEND=direct

