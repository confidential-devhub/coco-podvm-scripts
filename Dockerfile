FROM registry.access.redhat.com/ubi9/ubi:latest

RUN dnf -y update

# RUN rpm --import https://packages.microsoft.com/keys/microsoft.asc && \
#     dnf install -y https://packages.microsoft.com/config/rhel/9.0/packages-microsoft-prod.rpm && \
#     dnf install -y azure-cli

# packages needed
RUN dnf install -y cpio systemd-ukify jq openssl qemu-img libguestfs

# Add EPEL
RUN curl -O https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm && \
    dnf install -y epel-release-latest-9.noarch.rpm && \
    rm epel-release-latest-9.noarch.rpm

# Install dnf plugins
RUN dnf install -y dnf-plugins-core

# Install virt-customize and dependencies
RUN dnf install -y guestfs-tools libguestfs-tools

RUN dnf install -y sbsigntools

ADD scripts /scripts

ENV LIBGUESTFS_BACKEND=direct

ENV IMAGE_CERTIFICATE_PEM=/public.pem
ENV IMAGE_PRIVATE_KEY=/private.key

# Set default command
CMD ["/scripts/create-verity-podvm.sh", "/disk.qcow2"]