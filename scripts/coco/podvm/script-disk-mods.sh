#!/bin/bash
set -ex

export KERNEL_VERSION=6.12.0-211.16.1.el10_2
export NVIDIA_DRIVER_VERSION=595.58.03

dnf install -y kernel-{uki-virt,modules,modules-extra}-${KERNEL_VERSION}
# Update shim fallback CSV to ensure Azure VM boots latest UKI (needed only when kernel is updated)
printf "shimx64.efi,redhat,\\\EFI\\\Linux\\\\"`cat /etc/machine-id`"-"`rpm -q --queryformat %{VERSION}-%{RELEASE}\\\n kernel-uki-virt | tail -1`".x86_64.efi ,UKI bootentry\n" | iconv -f ASCII -t UCS-2 > /boot/efi/EFI/redhat/BOOTX64.CSV

# TODO: check if this still needed when we switch to using NVIDIA attestation RPMs.
dnf install -y xmlsec1 xmlsec1-openssl

##### NVIDIA DRIVERS
if [ -n "${NVIDIA_DRIVER_VERSION}" ]; then
  subscription-manager repos --enable=rhel-10-for-x86_64-supplementary-rpms
  subscription-manager repos --enable=rhel-10-for-x86_64-extensions-rpms
  dnf install -y --setopt=install_weak_deps=False nvidia-driver-${NVIDIA_DRIVER_VERSION} \
      nvidia-driver-cuda-${NVIDIA_DRIVER_VERSION} \
      nvidia-driver-libs-${NVIDIA_DRIVER_VERSION} \
      nvidia-persistenced-${NVIDIA_DRIVER_VERSION} \
      kmod-nvidia-open-${NVIDIA_DRIVER_VERSION}-${KERNEL_VERSION%.el*} \
      nvidia-container-toolkit
  dnf clean all

  echo -e "blacklist nouveau\nblacklist nova_core" > /etc/modprobe.d/blacklist_nv_alt.conf
  sed -i 's/^#no-cgroups = false/no-cgroups = true/' /etc/nvidia-container-runtime/config.toml

  cat << 'EOF' > /usr/local/bin/generate-nvidia-cdi.sh
#!/bin/bash

# Check if NVIDIA GPU is present
if ! lspci | grep -i nvidia > /dev/null 2>&1; then
    echo "No NVIDIA GPU detected, skipping NVIDIA setup" | tee /var/log/nvidia-cdi-gen.log
    exit 0
fi

# Load drivers
nvidia-ctk -d system create-device-nodes --control-devices --load-kernel-modules

nvidia-persistenced

# Set confidential compute to ready state (non-fatal if unsupported)
if nvidia-smi conf-compute -srs 1 2>/dev/null; then
    echo "Confidential Compute enabled" | tee -a /var/log/nvidia-cdi-gen.log
else
    echo "Could not set Confidential Compute GPUs to Ready State" | tee -a /var/log/nvidia-cdi-gen.log
fi

# Generate NVIDIA CDI configuration
nvidia-ctk cdi generate --output=/var/run/cdi/nvidia.yaml >> /var/log/nvidia-cdi-gen.log 2>&1 || exit 1
EOF
  chmod 755 /usr/local/bin/generate-nvidia-cdi.sh

  cat <<'EOF' > /etc/systemd/system/nvidia-cdi.service
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
fi
