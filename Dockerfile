FROM registry.access.redhat.com/ubi9/ubi:latest

ARG ORG_ID
ARG ACTIVATION_KEY

# This registering RHEL when building on an unsubscribed system
# If you are running a UBI container on a registered and subscribed RHEL host, 
# the main RHEL Server repository is enabled inside the standard UBI container.
# Uncomment this and provide the associated ARG variables to register.
RUN if [[ -n "${ACTIVATION_KEY}" && -n "${ORG_ID}" ]]; then \
    rm -f /etc/rhsm-host && rm -f /etc/pki/entitlement-host; \
    subscription-manager register --org=${ORG_ID} --activationkey=${ACTIVATION_KEY}; \
    fi


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
