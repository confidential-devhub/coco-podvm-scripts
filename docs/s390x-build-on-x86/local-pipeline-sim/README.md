# Local Pipeline Simulator — s390x PodVM Build

Replicates the Konflux/Tekton `build-dm-verity-image-s390x` pipeline on a local
Fyre RHEL 9 x86_64 VM so you can iterate on code changes without waiting for
CI/CD.

## How the pipeline actually works (what this replicates)

```
Tekton pod (x86)
  │
  ├─ Downloads RHEL 10.2 s390x DVD ISO from Red Hat CDN
  ├─ rsyncs source code + ISO to the remote VM
  └─ SSHs into remote VM → runs script-build.sh, which does:
       │
       ├─ podman build -f konflux/Dockerfile.s390x   ← builds builder-s390x image
       ├─ podman run -d --privileged builder-s390x    ← starts daemonised container
       ├─ podman exec → build-s390x-base-image.sh     ← Stage 1: Anaconda qcow2
       ├─ podman exec → create-verity-podvm-s390x.sh  ← Stage 2+3: CoCo + verity
       └─ podman run buildah → script-push.sh         ← push OCI image (skipped locally)
```

The local simulator runs the same three `podman` commands directly on the Fyre
VM, skipping the SSH/rsync and OCI push.

---

## One-time setup

### Prerequisites on the Fyre VM (`root@10.11.4.78`)

- RHEL 9.x x86_64 (stock Fyre image is fine)
- Root access
- Internet access (to pull Fedora 40 container images from `registry.fedoraproject.org`)
- ~50 GB free disk space (`/home/builder/`)

### Step 1 — Run the setup script

From your Mac:
```bash
ssh root@10.11.4.78 'bash -s' < setup-fyre-vm.sh
```

This installs `podman`, loads kernel modules (`nbd`, `loop`, `binfmt_misc`),
and creates the directory layout.

### Step 2 — Fill in your RHSM activation key

```bash
ssh root@10.11.4.78
echo 'YOUR_ORG_ID'         > /home/builder/activation-key/org
echo 'YOUR_ACTIVATION_KEY' > /home/builder/activation-key/activationkey
```

> Get these from https://access.redhat.com/management/activation_keys

### Step 3 — Place the RHEL 10.2 s390x DVD ISO

The ISO is ~8.4 GB. Two options:

**Option A — rsync from your Mac** (if you already have it):
```bash
rsync -P ~/Downloads/rhel-10.2-s390x-dvd.iso root@10.11.4.78:/home/builder/rhel.iso
```

**Option B — download directly on the Fyre VM** using your Red Hat offline token:
```bash
# On the Fyre VM:
OFFLINE_TOKEN="YOUR_OFFLINE_TOKEN"
TOKEN=$(curl -s https://sso.redhat.com/auth/realms/redhat-external/protocol/openid-connect/token \
  -d grant_type=refresh_token -d client_id=rhsm-api \
  -d refresh_token="$OFFLINE_TOKEN" | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")
curl -L "$(curl -s -H "Authorization: Bearer $TOKEN" \
  'https://api.access.redhat.com/management/v1/images/rhel/10.2/s390x' | \
  python3 -c "import sys,json; d=json.load(sys.stdin); print([x['downloadHref'] for x in d['body'] if x['filename']=='rhel-10.2-s390x-dvd.iso'][0])" \
  | xargs curl -s -H "Authorization: Bearer $TOKEN" | python3 -c "import sys,json; print(json.load(sys.stdin)['body']['href'])")" \
  -o /home/builder/rhel.iso
```

### Step 4 — Clone the repo

```bash
ssh root@10.11.4.78
git clone -b enable-support-s390x-podvm-build \
  https://github.com/rafsal-rahim/coco-podvm-scripts.git \
  /home/builder/source
```

---

## Running the build

### Full end-to-end run (first time)

```bash
ssh root@10.11.4.78
bash /home/builder/source/docs/s390x-build-on-x86/local-pipeline-sim/run-build.sh
```

**Expected time:** ~70–100 min total (Stage 1 Anaconda under TCG is slow).

### Skip flags for fast iteration

| Flag | When to use |
|---|---|
| `--skip-build` | Dockerfile.s390x unchanged; reuse existing `builder-s390x` image |
| `--skip-stage1` | Base qcow2 is already good; redo only CoCo + verity |
| `--skip-stage2` | Only want to test Stage 1 (Anaconda boot) |

```bash
# Changed a script in scripts/ or helpers/ — no Dockerfile change
bash run-build.sh --skip-build --skip-stage1

# Changed Dockerfile.s390x — rebuild image, but Stage 1 base is still good
bash run-build.sh --skip-stage1

# Full rebuild from scratch
bash run-build.sh
```

### Pull latest code changes

```bash
# Pull only (no image rebuild — fastest)
bash /home/builder/source/docs/s390x-build-on-x86/local-pipeline-sim/update-source.sh

# Pull + rebuild container image
bash /home/builder/source/docs/s390x-build-on-x86/local-pipeline-sim/update-source.sh --rebuild
```

---

## Inspecting a running build

The container is named `builder-s390x-run` and runs `sleep infinity` so you
can exec into it at any time:

```bash
# Shell into the running builder container
podman exec -it builder-s390x-run bash

# Watch QEMU Stage 1 output in real time
podman exec builder-s390x-run bash -c 'tail -f /tmp/qemu-stage1.log 2>/dev/null || echo "not started yet"'

# Check NBD mounts
podman exec builder-s390x-run bash -c 'ls /dev/nbd* && mount | grep nbd'

# Check disk image
podman exec builder-s390x-run bash -c 'qemu-img info /output/qcow2/disk.qcow2'
```

---

## Output

After a successful full run:

```
/home/builder/output/qcow2/disk.qcow2          ← dm-verity protected disk image
/home/builder/output/qcow2/disk.qcow2.roothash ← roothash (needed for VM boot)
```

The OCI push step is skipped locally. To test the disk on a real s390x LPAR,
follow Section 8–10 of the [runbook](../runbook-x86-to-s390x-podvm.md).

---

## Differences from the real pipeline

| Pipeline | Local simulator |
|---|---|
| ISO downloaded from Red Hat CDN | ISO rsync'd manually once |
| Source rsync'd from Tekton pod | Source cloned directly on Fyre VM |
| `--authfile` for Quay.io auth | Not needed (no OCI pull of private images) |
| OCI push via buildah | Skipped — disk stays at `/home/builder/output/` |
| `--pull=newer` on container run | `--pull=never` (use locally built image) |
| SSH tunnel through Tekton pod | Direct execution on Fyre VM |
