FROM quay.io/redhat-user-workloads/ose-osc-tenant/osc-podvm-payload@sha256:e8587a12eb61ea66daf5ff1605b04fe442684b6254c0d37c3a07789c61418a9a as payload

FROM registry.redhat.io/ubi9/ubi-init@sha256:166697ef294f6c499c8423ec4818006ee8025af7ad92ecd80eb4175553533415

RUN subscription-manager register --org "$(cat /activation-key/org)" --activationkey "$(cat /activation-key/activationkey)"

RUN dnf install -y \
cpio systemd-ukify jq openssl qemu-img libguestfs guestfs-tools libguestfs-tools virt-install qemu-kvm edk2-ovmf nc

COPY qemu.conf /etc/libvirt/qemu.conf

COPY --from=payload /podvm-binaries.tar.gz /payload/
COPY --from=payload /pause-bundle.tar.gz /payload/

# to make virt-customize work
ENV LIBGUESTFS_BACKEND=direct

