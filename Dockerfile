FROM registry.access.redhat.com/ubi9/ubi:latest

RUN dnf -y update

# packages needed
RUN dnf install -y cpio systemd-ukify jq openssl qemu-img libguestfs

# Add EPEL
RUN curl -O https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm && \
    dnf install -y epel-release-latest-9.noarch.rpm && \
    rm epel-release-latest-9.noarch.rpm

# Install dnf plugins
# RUN dnf install -y dnf-plugins-core

# Install virt-customize and dependencies
RUN dnf install -y guestfs-tools libguestfs-tools sbsigntools

# scripts
ADD scripts /scripts

# to make virt-customize work
ENV LIBGUESTFS_BACKEND=direct

# default env for certs
ENV IMAGE_CERTIFICATE_PEM=/public.pem
ENV IMAGE_PRIVATE_KEY=/private.key

CMD ["/scripts/create-verity-podvm.sh", "/disk.qcow2"]