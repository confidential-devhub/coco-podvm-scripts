#! /bin/bash
set -euo pipefail

# this script assumes system is already registered with subscription-manager

# Nvidia driver and configuration

export DRIVER_VERSION="580.82.07"
export KERNEL_VERSION=$(rpm -q --qf "%{VERSION}" kernel-uki-virt)
export KERNEL_RELEASE=$(rpm -q --qf "%{RELEASE}" kernel-uki-virt | sed 's/\.el.*$//')
export ARCH=$(uname -m)
# TODO: adapt - kernel headers doesn't always has the same exact kernel version
dnf install -y gcc kernel-devel-${KERNEL_VERSION}-${KERNEL_RELEASE}.* kernel-devel-matched-${KERNEL_VERSION}-${KERNEL_RELEASE}.*
subscription-manager repos --enable codeready-builder-for-rhel-10-$(arch)-rpms
dnf install https://dl.fedoraproject.org/pub/epel/epel-release-latest-10.noarch.rpm -y
dnf install -y dkms #--exclude=kernel\*
dnf config-manager --add-repo=https://developer.download.nvidia.com/compute/cuda/repos/rhel10/x86_64/cuda-rhel10.repo
dnf install -y nvidia-driver-cuda-${DRIVER_VERSION} kmod-nvidia-open-dkms-${DRIVER_VERSION} --exclude=kernel\*
dkms build -m nvidia -v ${DRIVER_VERSION} -k $(rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}' kernel-uki-virt) || cat /var/lib/dkms/nvidia/${DRIVER_VERSION}/build/make.log
dkms install -m nvidia -v ${DRIVER_VERSION} -k $(rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}' kernel-uki-virt)
dnf config-manager --add-repo=https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo
dnf install --repo nvidia-container-toolkit -y nvidia-container-toolkit
dnf clean all

echo -e "blacklist nouveau\nblacklist nova_core" > /etc/modprobe.d/blacklist_nv_alt.conf
sed -i 's/^#no-cgroups = false/no-cgroups = true/' /etc/nvidia-container-runtime/config.toml

cat << EOF > /usr/local/bin/generate-nvidia-cdi.sh
#!/bin/bash

#load drivers
nvidia-ctk -d system create-device-nodes --control-devices --load-kernel-modules

nvidia-persistenced
# set confidential compute to ready state
nvidia-smi conf-compute -srs 1
# Generate NVIDIA CDI configuration
nvidia-ctk cdi generate --output=/var/run/cdi/nvidia.yaml > /var/log/nvidia-cdi-gen.log 2>&1
EOF
chmod 755 /usr/local/bin/generate-nvidia-cdi.sh

cat <<EOF > /etc/systemd/system/nvidia-cdi.service
[Unit]
Description=Generate NVIDIA CDI Configuration
Before=kata-agent.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/generate-nvidia-cdi.sh
RemainAfterExit=true

[Install]
WantedBy=multi-user.target
EOF
chmod 644 /etc/systemd/system/nvidia-cdi.service
ln -s /etc/systemd/system/nvidia-cdi.service /etc/systemd/system/multi-user.target.wants/nvidia-cdi.service

