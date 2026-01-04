#!/bin/bash
set -ex

export KERNEL_VERSION=6.12.0-124.21.1.el10_1

dnf install -y kernel-{uki-virt,modules,modules-extra}-${KERNEL_VERSION}
# Update shim fallback CSV to ensure Azure VM boots latest UKI (needed only when kernel is updated)
printf "shimx64.efi,redhat,\\\EFI\\\Linux\\\\"`cat /etc/machine-id`"-"`rpm -q --queryformat %{VERSION}-%{RELEASE}\\\n kernel-uki-virt | tail -1`".x86_64.efi ,UKI bootentry\n" | iconv -f ASCII -t UCS-2 > /boot/efi/EFI/redhat/BOOTX64.CSV
