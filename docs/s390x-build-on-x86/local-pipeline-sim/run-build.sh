#!/bin/bash
# =============================================================================
# run-build.sh — Local pipeline simulator for the s390x PodVM dm-verity build.
#
# Replicates EXACTLY what Konflux/Tekton does on the remote x86 VM:
#   1. podman build -f konflux/Dockerfile.s390x  (builds builder-s390x image)
#   2. podman run -d --privileged builder-s390x  (starts daemonised container)
#   3. podman exec → build-s390x-base-image.sh   (Stage 1: Anaconda qcow2)
#   4. podman exec → create-verity-podvm-s390x.sh (Stage 2+3: CoCo + verity)
#
# OCI push is SKIPPED — the disk image is left at ./output/qcow2/disk.qcow2
# for manual inspection.
#
# Usage (run as root on the Fyre VM):
#   bash run-build.sh [--skip-build] [--skip-stage1] [--skip-stage2]
#
#   --skip-build   : skip podman build (reuse existing builder-s390x image)
#   --skip-stage1  : skip Stage 1 (reuse existing disk.qcow2 base image)
#   --skip-stage2  : skip Stage 2+3 (only build base image in Stage 1)
#
# Examples:
#   bash run-build.sh                        # full end-to-end run
#   bash run-build.sh --skip-build           # code changed, image cached
#   bash run-build.sh --skip-stage1          # base image ok, redo CoCo+verity
# =============================================================================
set -euo pipefail

# ── Parse flags ───────────────────────────────────────────────────────────────
SKIP_BUILD=0
SKIP_STAGE1=0
SKIP_STAGE2=0
for arg in "$@"; do
  case $arg in
    --skip-build)   SKIP_BUILD=1   ;;
    --skip-stage1)  SKIP_STAGE1=1  ;;
    --skip-stage2)  SKIP_STAGE2=1  ;;
    *) echo "Unknown flag: $arg"; exit 1 ;;
  esac
done

# ── Configuration (mirrors the Tekton pipeline) ───────────────────────────────
BUILD_DIR=/home/builder
SOURCE_DIR="$BUILD_DIR/source"
ISO_PATH="$BUILD_DIR/rhel.iso"
OUTPUT_DIR="$BUILD_DIR/output/qcow2"
DISK="$OUTPUT_DIR/disk.qcow2"
KERNEL_VERSION="6.12.0-211.16.1.el10_2"

# ── Pre-flight checks ─────────────────────────────────────────────────────────
echo "========================================================"
echo " s390x Pipeline Simulator — Pre-flight"
echo "========================================================"

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: must run as root (sudo or root session)"
  exit 1
fi

if [[ ! -f "$BUILD_DIR/activation-key/org" ]] || \
   grep -q "REPLACE_WITH" "$BUILD_DIR/activation-key/org" 2>/dev/null; then
  echo "ERROR: $BUILD_DIR/activation-key/org not set."
  echo "       echo 'YOUR_ORG_ID' > $BUILD_DIR/activation-key/org"
  exit 1
fi

if [[ ! -f "$BUILD_DIR/activation-key/activationkey" ]] || \
   grep -q "REPLACE_WITH" "$BUILD_DIR/activation-key/activationkey" 2>/dev/null; then
  echo "ERROR: $BUILD_DIR/activation-key/activationkey not set."
  echo "       echo 'YOUR_KEY' > $BUILD_DIR/activation-key/activationkey"
  exit 1
fi

if [[ $SKIP_STAGE1 -eq 0 ]] && [[ ! -f "$ISO_PATH" ]]; then
  echo "ERROR: ISO not found at $ISO_PATH"
  echo "       Place rhel-10.2-s390x-dvd.iso there or use --skip-stage1"
  exit 1
fi

if [[ ! -d "$SOURCE_DIR/.git" ]]; then
  echo "ERROR: Repo not cloned at $SOURCE_DIR"
  echo "       git clone -b enable-support-s390x-podvm-build \\"
  echo "         https://github.com/rafsal-rahim/coco-podvm-scripts.git \\"
  echo "         $SOURCE_DIR"
  exit 1
fi

# Ensure kernel modules are loaded
modprobe nbd max_part=8 2>/dev/null || true
modprobe loop 2>/dev/null || true
modprobe binfmt_misc 2>/dev/null || true

mkdir -p "$OUTPUT_DIR"

echo "  SOURCE_DIR   : $SOURCE_DIR ($(cd $SOURCE_DIR && git log --oneline -1))"
echo "  ISO          : ${ISO_PATH} $([ -f "$ISO_PATH" ] && echo "✓" || echo "(skipped)")"
echo "  OUTPUT_DIR   : $OUTPUT_DIR"
echo "  KERNEL_VER   : $KERNEL_VERSION"
echo "  SKIP_BUILD   : $SKIP_BUILD"
echo "  SKIP_STAGE1  : $SKIP_STAGE1"
echo "  SKIP_STAGE2  : $SKIP_STAGE2"
echo ""

# ── Step 1: podman build ──────────────────────────────────────────────────────
# Mirrors the pipeline exactly:
#   sudo podman build --authfile=... -v .../activation-key/:/activation-key/:Z \
#     -t builder-s390x -f .../Dockerfile.s390x ...
if [[ $SKIP_BUILD -eq 0 ]]; then
  echo "========================================================"
  echo " Step 1: Building builder-s390x container image"
  echo " (from konflux/Dockerfile.s390x)"
  echo "========================================================"
  time podman build \
    -v "$BUILD_DIR/activation-key/:/activation-key/:Z" \
    -t builder-s390x \
    -f "$SOURCE_DIR/konflux/Dockerfile.s390x" \
    "$SOURCE_DIR"
  echo "→ builder-s390x image built ✓"
else
  echo "→ Step 1 SKIPPED (--skip-build)"
  if ! podman image exists builder-s390x; then
    echo "ERROR: builder-s390x image does not exist — cannot skip build on first run"
    exit 1
  fi
fi

# ── Step 2: Start daemonised container ────────────────────────────────────────
# Mirrors the pipeline exactly — same flags, same mounts, same env vars.
# Key flags explained:
#   --privileged            : required for NBD, loop, binfmt_misc, veritysetup
#   --mount source=/dev     : qemu-system-s390x needs /dev/kvm (or falls back to TCG)
#   --mount source=/run/udev: udev events for partition discovery (partprobe)
#   -v /lib/modules:ro      : modprobe nbd/loop inside container
#   LIBGUESTFS_BACKEND=direct: bypass libvirt for libguestfs (container-safe)
#   LIBGUESTFS_HV=...       : use our qemu-system-s390x, not the default x86 one
echo ""
echo "========================================================"
echo " Step 2: Starting builder-s390x container (daemonised)"
echo "========================================================"

# Stop any leftover container from a previous run
PREV=$(podman ps -q --filter name=builder-s390x-run 2>/dev/null || true)
if [[ -n "$PREV" ]]; then
  echo "  Stopping leftover container $PREV ..."
  podman stop "$PREV" 2>/dev/null || true
fi

podman run -d \
  --name builder-s390x-run \
  --rm \
  --privileged \
  --pull=never \
  -v "${BUILD_DIR}:/workspace" \
  -v "${OUTPUT_DIR}:/output/qcow2" \
  -v /lib/modules:/lib/modules:ro,Z \
  -v "$BUILD_DIR/activation-key/:/activation-key/:Z" \
  --user 0 \
  --security-opt=apparmor=unconfined \
  --security-opt=seccomp=unconfined \
  --mount type=bind,source=/dev,target=/dev \
  --mount type=bind,source=/run/udev,target=/run/udev \
  --env=LIBGUESTFS_BACKEND=direct \
  --env=LIBGUESTFS_HV=/usr/bin/qemu-system-s390x \
  builder-s390x \
  sleep infinity     # keep it running; we exec into it

echo "  → Container started: builder-s390x-run ✓"
echo "    (use: podman exec -it builder-s390x-run bash  to inspect)"

# ── Step 3: Stage 1 — Anaconda base image ────────────────────────────────────
# Mirrors:
#   podman exec -t --latest bash -c "
#     export ORG_ID=$(cat /activation-key/org)
#     ...
#     bash /workspace/source/helpers/build-s390x-base-image.sh
#   "
if [[ $SKIP_STAGE1 -eq 0 ]]; then
  echo ""
  echo "========================================================"
  echo " Step 3: Stage 1 — s390x base qcow2 (Anaconda via QEMU)"
  echo " This takes ~60-90 minutes under TCG emulation."
  echo "========================================================"
  time podman exec -t builder-s390x-run bash -c "
    set -euo pipefail
    export ORG_ID=\$(cat /activation-key/org)
    export ACTIVATION_KEY=\$(cat /activation-key/activationkey)
    export ISO_PATH=/workspace/rhel.iso
    export OUTPUT_DIR=/output/qcow2
    export OUTPUT_NAME=disk.qcow2
    export DISK_SIZE_GB=7
    export VM_MEMORY_MB=8192
    bash /workspace/source/helpers/build-s390x-base-image.sh
  "
  echo "→ Stage 1 complete ✓  (disk at $DISK)"
else
  echo "→ Stage 1 SKIPPED (--skip-stage1)"
  if [[ ! -f "$DISK" ]]; then
    echo "ERROR: $DISK not found — cannot skip Stage 1 on first run"
    exit 1
  fi
fi

# ── Step 4: Stage 2+3 — CoCo components + dm-verity ─────────────────────────
# Mirrors:
#   podman exec -t --latest bash -c "
#     export ORG_ID=...
#     export ARTIFACTS_FOLDER=...
#     export KERNEL_VERSION=...
#     bash /workspace/source/scripts/create-verity-podvm-s390x.sh /output/qcow2/disk.qcow2
#   "
if [[ $SKIP_STAGE2 -eq 0 ]]; then
  echo ""
  echo "========================================================"
  echo " Step 4: Stage 2+3 — CoCo components + dm-verity"
  echo "========================================================"
  time podman exec -t builder-s390x-run bash -c "
    set -euo pipefail
    export ORG_ID=\$(cat /activation-key/org)
    export ACTIVATION_KEY=\$(cat /activation-key/activationkey)
    export ARTIFACTS_FOLDER=/workspace/source/scripts/coco/podvm
    export KERNEL_VERSION=$KERNEL_VERSION
    bash /workspace/source/scripts/create-verity-podvm-s390x.sh /output/qcow2/disk.qcow2
  "
  echo "→ Stage 2+3 complete ✓"
else
  echo "→ Stage 2+3 SKIPPED (--skip-stage2)"
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "========================================================"
echo " Build complete."
echo ""
echo " Artifacts:"
echo "   Disk image : $DISK"
if [[ -f "${DISK}.roothash" ]]; then
  echo "   Roothash   : $(cat ${DISK}.roothash)"
fi
echo ""
echo " Container is still running as 'builder-s390x-run'."
echo " Inspect:  podman exec -it builder-s390x-run bash"
echo " Stop:     podman stop builder-s390x-run"
echo "========================================================"
