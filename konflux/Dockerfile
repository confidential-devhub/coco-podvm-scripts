FROM quay.io/redhat-user-workloads/ose-osc-tenant/osc-podvm-payload@sha256:0ce0a12dba85faca061b84afeb807bcfc1135ffff7d4d1aaacb134b10db15739 as payload

FROM registry.redhat.io/ubi9/ubi-init@sha256:166697ef294f6c499c8423ec4818006ee8025af7ad92ecd80eb4175553533415

RUN subscription-manager register --org "$(cat /activation-key/org)" --activationkey "$(cat /activation-key/activationkey)"

RUN dnf install -y \
cpio systemd-ukify jq openssl qemu-img libguestfs guestfs-tools libguestfs-tools virt-install qemu-kvm edk2-ovmf nc

COPY qemu.conf /etc/libvirt/qemu.conf

COPY --from=payload /podvm-binaries.tar.gz /payload/
COPY --from=payload /pause-bundle.tar.gz /payload/

# to make virt-customize work
ENV LIBGUESTFS_BACKEND=direct

