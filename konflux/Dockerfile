FROM quay.io/redhat-user-workloads/ose-osc-tenant/osc-podvm-payload@sha256:ee121931b017afffcd2d9f542c071bf63df140ff3bcc2d9036eca2bf9dd66544 as payload

FROM registry.redhat.io/ubi9/ubi-init@sha256:5cb5b3edcf6fe5e603678c15c89567847be799e4a179b51ba8e2631a2b48273a

RUN subscription-manager register --org "$(cat /activation-key/org)" --activationkey "$(cat /activation-key/activationkey)"

RUN dnf install -y \
cpio systemd-ukify jq openssl qemu-img libguestfs guestfs-tools libguestfs-tools virt-install qemu-kvm edk2-ovmf nc

COPY qemu.conf /etc/libvirt/qemu.conf

COPY --from=payload /podvm-binaries.tar.gz /payload/
COPY --from=payload /pause-bundle.tar.gz /payload/

# to make virt-customize work
ENV LIBGUESTFS_BACKEND=direct

