#!/bin/bash

LUKS_DEV="/dev/disk/by-partlabel/scratch"
MOUNT_POINT="/kata-containers"
MAPPER_NAME="scratch"
KEY_PATH=/run/lukspw.bin

echo "Formatting $LUKS_DEV into LUKS..."

dd if=/dev/urandom of=$KEY_PATH bs=64 count=1
echo "Random key generated in $KEY_PATH"

if ! cryptsetup luksFormat --type luks2 --cipher aes-xts-plain64 --key-size 512 --hash sha256 --batch-mode "$LUKS_DEV" --key-file $KEY_PATH; then
    echo "ERROR: Failed to luksFormat $LUKS_DEV. Aborting."
    exit 1
fi
echo "$LUKS_DEV formatted with key $KEY_PATH"

if ! cryptsetup luksOpen "$LUKS_DEV" "$MAPPER_NAME" --key-file $KEY_PATH; then
    echo "ERROR: Failed to luksOpen $LUKS_DEV. Aborting."
    exit 1
fi
echo "$LUKS_DEV opened /dev/mapper/$MAPPER_NAME"

if ! mkfs.ext4 -F "/dev/mapper/$MAPPER_NAME"; then
    echo "ERROR: Failed to create ext4 on /dev/mapper/$MAPPER_NAME. Aborting."
    exit 1
fi
echo "Created ext4 filesystem on /dev/mapper/$MAPPER_NAME"

echo "Process completed."