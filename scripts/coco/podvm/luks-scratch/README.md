# LUKS scratch partition

This directory holds the guest-side files that give the pod VM an **encrypted
scratch partition**: a block device created and LUKS2-encrypted inside the
guest at every boot, with a key that never leaves the VM.

It is installed into every dm-verity pod VM image we build, and it is always
on — there is no flag to turn it off.

## Why it exists

The pod VM is designed to run as a confidential VM (CVM). The CPU encrypts its
*memory*, but **not** the virtual disk attached to it — the disk is ordinary
cloud storage that the cloud provider can read. Separately, the root
filesystem of our image is dm-verity protected, which makes it read-only and
tamper-evident.

That leaves a gap. A confidential pod pulls its container images *inside* the
guest (guest pull, so the host never sees the decrypted image) and the
container then needs somewhere writable to run. Writing that to the plain
virtual disk would hand the container's filesystem to the cloud provider in
cleartext.

So the guest makes its own encrypted disk:

| Protects | Mechanism |
| --- | --- |
| Memory | CPU/TEE (AMD SEV-SNP, Intel TDX) |
| Root filesystem (read-only) | dm-verity — see `scripts/verity/verity.sh` |
| **Writable container data** | **LUKS2, this directory** |

### Caveat: this image is also used without a CVM

OpenShift sandboxed containers uses this image as its **default pod VM image
for all x86_64 providers**, not only for confidential containers. Whether the
VM is launched as a CVM is a runtime decision (`DISABLECVM` in
`peer-pods-cm`), taken long after the image is built.

When the VM is not a CVM, the hypervisor can read guest memory, and the LUKS
key is in guest memory. The encryption then no longer protects against the
cloud provider — it only provides encryption at rest, which still matters for
leftover volumes and snapshots, since the key is gone once the VM stops. The
full guarantee holds only when the VM is a CVM.

## Files

| File | Role |
| --- | --- |
| `usr/local/sbin/create-scratch.sh` | Creates, encrypts and opens the partition |
| `etc/systemd/system/luks-scratch.service` | Runs the script at boot, before `kata-agent` |
| `etc/systemd/system/kata-agent.service.d/10-override.conf` | Mounts the opened device for `kata-agent` |
| `build.sh` | Tars `usr/` + `etc/` into `../luks-config.tar.gz` |

The Konflux production build keeps a copy of the same three files under
`konflux/podvm-root/`, shipped as `podvm-root.tar.gz`. **Keep the two trees in
sync** — the dev path (`scripts/`) and the production path (`konflux/`) are
built independently.

## How it works

### At image build time — reserve the space

`scripts/verity/verity.sh` grows the disk image *before* partitioning it:

```sh
LUKS_MINIMAL_SPACE_MB=2500                        # verity.sh:67
verity_max_space=$((current_size * 7 / 100))      # 7% for the verity hash tree
new_size=$((current_size + luks_min_space + verity_max_space))
```

`apply_dmverity()` then caps the root partition at its original size and the
verity partition at `verity_max_space`, so the extra 2500 MiB is left
**unallocated** at the end of the disk. Nothing is created there at build
time; it is just free space waiting for the guest.

The Konflux task does the same thing at
`task/build-dm-verity-image/0.1/build-dm-verity-image.yaml:380-390`.

The unit is enabled in the image by `scripts/coco/podvm/podvm_maker.sh`
(`systemctl enable /etc/systemd/system/luks-scratch.service`) and, for
production, at `build-dm-verity-image.yaml:353`.

### At boot — create, encrypt, open, mount

```
systemd-repart.service
        │
        ▼
luks-scratch.service  ──►  create-scratch.sh
        │                       1. 64 random bytes -> /run/lukspw.bin  (tmpfs)
        │                       2. systemd-repart: new partition in the free
        │                          space, LUKS2 on top, ext4 inside
        │                       3. cryptsetup luksOpen -> /dev/mapper/scratch
        ▼
kata-agent.service    ──►  ExecStartPre mounts /dev/mapper/scratch
```

`create-scratch.sh` hands systemd-repart a throwaway definition rather than
shipping one in `/usr/lib/repart.d`, so the partition is only ever created by
this unit:

```ini
[Partition]
Type=linux-generic
Label=scratch
Encrypt=key-file
Format=ext4
```

`Encrypt=key-file` is what makes systemd-repart lay down a LUKS2 volume keyed
by `--key-file` and put the ext4 filesystem *inside* it. The script then reads
the created device node out of repart's JSON output with `jq` and opens it as
`/dev/mapper/scratch`.

Because the definition sets no `SizeMaxBytes`, repart grows the partition to
fill whatever space is unallocated — at least the ~2.4 GiB (2500 MiB) the
build reserved.

## Properties worth knowing

**The key is ephemeral and guest-only.** 64 bytes from the guest's
`/dev/urandom`, written to `/run/lukspw.bin`, which is tmpfs. It is never
persisted, never sent anywhere, and is not derived from attestation or fetched
from Trustee. It dies with the VM.

**Every boot gets a fresh partition and a fresh key.** Nothing from a previous
boot is recoverable, by anyone, including us. Pod VMs are single-use, so in
practice this is per-pod.

**Confidentiality, not integrity.** This is plain LUKS2/dm-crypt with no
`--integrity`. Someone who can write to the backing disk cannot read the data,
but can corrupt it, and the guest will not detect the tampering
cryptographically. Contrast with the root filesystem, which *is* integrity
protected by dm-verity.

**It fails closed.** The `ExecStartPre` in `10-override.conf` is not prefixed
with `-`, so if `/dev/mapper/scratch` is missing the command exits non-zero and
`kata-agent.service` refuses to start. A pod VM that cannot set up encrypted
scratch does not fall back to unencrypted storage; it fails.

**There is no configuration.** No kernel command line, no environment
variable, no file to drop in, and no way for a consumer of the image to turn
it off. If you need to disable it for debugging, you have to build an image
without the unit enabled.

**It is not gated on confidential computing.** The unit is enabled at build
time and knows nothing about whether the VM it boots in is a CVM — see the
caveat above.
