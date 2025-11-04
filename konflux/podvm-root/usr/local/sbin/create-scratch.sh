#!/bin/bash

KEY_PATH=/run/lukspw.bin
WORKDIR=$(mktemp -d)

dd if=/dev/urandom of=$KEY_PATH bs=64 count=1
echo "Random key generated in $KEY_PATH"

echo "[Partition]
Type=linux-generic
Label=scratch
Encrypt=key-file
Format=ext4" > $WORKDIR/scratch.conf

out=$(SYSTEMD_LOG_LEVEL=debug systemd-repart --dry-run=no --key-file=$KEY_PATH --definitions=$WORKDIR --no-pager --json=pretty)

echo $out

sda=$(echo $out | jq -r '.[] | select(.activity=="create") | .node')

echo $sda

cryptsetup luksOpen $sda scratch --key-file $KEY_PATH

rm -rf $WORKDIR

echo "Process completed."
