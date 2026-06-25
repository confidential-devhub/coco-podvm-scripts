#!/bin/bash
set -e

KEY_PATH=/run/lukspw.bin
WORKDIR=$(mktemp -d)
NVME_DEVICE=""
TARGET_DEVICE=""

# Function to detect NVMe device
detect_nvme() {
    echo "Detecting NVMe devices..."
    
    # Look for NVMe devices (typically /dev/nvme0n1, /dev/nvme1n1, etc.)
    for nvme in /dev/nvme[0-9]n[0-9]; do
        if [ -b "$nvme" ]; then
            echo "Found NVMe device: $nvme"
            
            # Check if device is not already partitioned or in use
            if ! lsblk "$nvme" | grep -q part; then
                NVME_DEVICE="$nvme"
                echo "Using NVMe device: $NVME_DEVICE"
                return 0
            else
                echo "NVMe device $nvme already has partitions, checking next..."
            fi
        fi
    done
    
    echo "No available NVMe device found"
    return 1
}

# Function to setup NVMe device directly (without systemd-repart)
setup_nvme_scratch() {
    local nvme_dev="$1"
    
    echo "Setting up LUKS scratch partition on NVMe device: $nvme_dev"
    
    # Wipe any existing filesystem signatures
    wipefs -a "$nvme_dev" 2>/dev/null || true
    
    # Create a single partition using the entire disk
    parted -s "$nvme_dev" mklabel gpt
    parted -s "$nvme_dev" mkpart primary ext4 0% 100%
    
    # Wait for partition to be created
    sleep 2
    partprobe "$nvme_dev"
    udevadm settle
    
    # The partition will be ${nvme_dev}p1 (e.g., /dev/nvme0n1p1)
    local nvme_part="${nvme_dev}p1"
    
    # Wait for partition device to appear
    local retries=10
    while [ ! -b "$nvme_part" ] && [ $retries -gt 0 ]; do
        echo "Waiting for partition $nvme_part to appear..."
        sleep 1
        retries=$((retries - 1))
    done
    
    if [ ! -b "$nvme_part" ]; then
        echo "ERROR: Partition $nvme_part did not appear"
        return 1
    fi
    
    echo "Partition created: $nvme_part"
    
    # Format with LUKS
    echo "Encrypting partition with LUKS..."
    cryptsetup luksFormat --type luks2 --key-file "$KEY_PATH" "$nvme_part"
    
    # Open LUKS device
    echo "Opening LUKS device..."
    cryptsetup luksOpen "$nvme_part" scratch --key-file "$KEY_PATH"
    
    # Format with ext4
    echo "Creating ext4 filesystem..."
    mkfs.ext4 -L scratch /dev/mapper/scratch
    
    echo "NVMe scratch partition setup completed: /dev/mapper/scratch"
    return 0
}

# Function to setup scratch using systemd-repart (fallback to root disk)
setup_systemd_repart_scratch() {
    echo "Using systemd-repart on root disk (fallback mode)"
    
    echo "[Partition]
    Type=linux-generic
    Label=scratch
    Encrypt=key-file
    Format=ext4" > $WORKDIR/scratch.conf

    out=$(SYSTEMD_LOG_LEVEL=debug systemd-repart --dry-run=no --key-file=$KEY_PATH --definitions=$WORKDIR --no-pager --json=pretty)
    
    echo "$out"
    
    sda=$(echo "$out" | jq -r '.[] | select(.activity=="create") | .node')
    
    if [ -z "$sda" ]; then
        echo "ERROR: systemd-repart did not create a partition"
        return 1
    fi
    
    echo "Partition created: $sda"
    
    cryptsetup luksOpen "$sda" scratch --key-file "$KEY_PATH"
    
    echo "Root disk scratch partition setup completed: /dev/mapper/scratch"
    return 0
}

# Main execution
echo "=== Kata Containers Scratch Partition Setup ==="

# Generate encryption key
dd if=/dev/urandom of=$KEY_PATH bs=64 count=1 2>/dev/null
echo "Random LUKS key generated at $KEY_PATH"

# Try to detect and use NVMe device first
if detect_nvme && [ -n "$NVME_DEVICE" ]; then
    if setup_nvme_scratch "$NVME_DEVICE"; then
        TARGET_DEVICE="$NVME_DEVICE"
        echo "SUCCESS: Using NVMe device for scratch partition"
    else
        echo "WARNING: NVMe setup failed, falling back to root disk"
        setup_systemd_repart_scratch
        TARGET_DEVICE="root disk"
    fi
else
    # Fallback to systemd-repart on root disk
    echo "No NVMe device available, using root disk"
    setup_systemd_repart_scratch
    TARGET_DEVICE="root disk"
fi

# Cleanup
rm -rf $WORKDIR

# Verify the scratch device is available
if [ -b /dev/mapper/scratch ]; then
    echo "=== Setup Complete ==="
    echo "Scratch device: /dev/mapper/scratch"
    echo "Source device: $TARGET_DEVICE"
    lsblk /dev/mapper/scratch
else
    echo "ERROR: /dev/mapper/scratch was not created"
    exit 1
fi
