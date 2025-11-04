#! /bin/bash
set -euo pipefail

# this script assumes system is already registered with subscription-manager

# Nvidia driver and configuration

subscription-manager repos --enable=rhel-10-for-x86_64-supplementary-rpms
subscription-manager repos --enable=rhel-10-for-x86_64-extensions-rpms

# update UKI
# make sure driver and kernel match
KERNEL_VERSION=`rpm -q --queryformat %{VERSION}-%{RELEASE}\\\n kernel-uki-virt | tail -1`
NVIDIA_DRIVER_VERSION=580.95.05

dnf install -y kernel-{uki-virt,modules,modules-extra}-${KERNEL_VERSION}
# Update shim fallback CSV to ensure Azure VM boots latest UKI (needed only when kernel is updated)
#printf "shimx64.efi,redhat,\\\EFI\\\Linux\\\\"`cat /etc/machine-id`"-"`rpm -q --queryformat %{VERSION}-%{RELEASE}\\\n kernel-uki-virt | tail -1`".x86_64.efi ,UKI bootentry\n" | iconv -f ASCII -t UCS-2 > /boot/efi/EFI/redhat/BOOTX64.CSV
dnf install -y nvidia-driver-${NVIDIA_DRIVER_VERSION} \
    nvidia-driver-cuda-${NVIDIA_DRIVER_VERSION} \
    nvidia-driver-libs-${NVIDIA_DRIVER_VERSION} \
    nvidia-persistenced-${NVIDIA_DRIVER_VERSION} \
    kmod-nvidia-open-${NVIDIA_DRIVER_VERSION}-${KERNEL_VERSION%.el*}
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
