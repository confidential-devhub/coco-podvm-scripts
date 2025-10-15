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

SYSTEMD_LOG_LEVEL=debug systemd-repart --dry-run=no --key-file=$KEY_PATH --definitions=$WORKDIR --no-pager

rm -rf $WORKDIR

echo "Process completed."
