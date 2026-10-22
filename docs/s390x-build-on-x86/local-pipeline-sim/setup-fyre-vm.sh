#!/bin/bash
# =============================================================================
# setup-fyre-vm.sh — One-time setup of a Fyre RHEL 9 VM to replicate the
#                    Konflux/Tekton s390x pipeline environment locally.
#
# Run this ONCE on the Fyre VM as root:
#   ssh root@10.11.4.78 'bash -s' < setup-fyre-vm.sh
#
# After this runs, use run-build.sh to iterate on code changes.
# =============================================================================
set -euo pipefail

echo "========================================================"
echo " Fyre VM Pipeline Simulator — One-time Setup"
echo " Replicates: Konflux multi-platform-controller x86_64 VM"
echo "========================================================"

# ── 0. Fail fast if not root ──────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  echo "ERROR: Run as root (ssh root@<fyre-ip>)"
  exit 1
fi

# ── 1. Install podman + supporting tools ─────────────────────────────────────
echo "[1/6] Installing podman, git, rsync, blkid ..."
dnf install -y podman git rsync util-linux

# The pipeline VM runs RHEL 9; podman is already available.
# kmod nbd must be loadable — verify the module exists.
if ! modinfo nbd &>/dev/null; then
  echo "WARNING: nbd kernel module not found — Stage 2 may fail."
  echo "         Try: dnf install -y kernel-modules-extra && reboot"
fi

# ── 2. Load kernel modules (same as pipeline VM pre-flight) ──────────────────
echo "[2/6] Loading kernel modules ..."
modprobe nbd max_part=8 || echo "WARNING: nbd load failed — may need kernel-modules-extra"
modprobe loop
modprobe binfmt_misc || true

# Persist across reboots
cat > /etc/modules-load.d/pipeline-sim.conf <<'EOF'
nbd
loop
binfmt_misc
EOF

cat > /etc/modprobe.d/nbd.conf <<'EOF'
options nbd max_part=8
EOF

# ── 3. Create directory layout (mirrors Tekton pipeline VM) ──────────────────
# Pipeline VM layout that script-build.sh expects:
#   $BUILD_DIR/                   → /home/builder
#   $BUILD_DIR/source/            → cloned repo (rsync'd from Tekton pod)
#   $BUILD_DIR/activation-key/   → org + activationkey files
#   $BUILD_DIR/rhel.iso           → RHEL 10.2 s390x DVD ISO
#   $(pwd)/output/qcow2/          → where script-build.sh writes disk.qcow2
echo "[3/6] Creating directory layout ..."
BUILD_DIR=/home/builder
mkdir -p \
  "$BUILD_DIR/source" \
  "$BUILD_DIR/activation-key" \
  "$BUILD_DIR/scripts" \
  "$BUILD_DIR/tekton-results" \
  "$BUILD_DIR/.docker"
mkdir -p /home/builder/output/qcow2

# ── 4. Write the activation-key files ────────────────────────────────────────
# The pipeline reads these via: cat /activation-key/org
# and:                          cat /activation-key/activationkey
echo "[4/6] Writing activation-key files ..."
echo "NOTE: Edit these files with your RHSM credentials before running the build."

# Write placeholder files — user must fill these in
if [[ ! -f "$BUILD_DIR/activation-key/org" ]]; then
  echo "REPLACE_WITH_YOUR_ORG_ID" > "$BUILD_DIR/activation-key/org"
  echo "  → Created $BUILD_DIR/activation-key/org  (EDIT THIS)"
fi

if [[ ! -f "$BUILD_DIR/activation-key/activationkey" ]]; then
  echo "REPLACE_WITH_YOUR_ACTIVATION_KEY" > "$BUILD_DIR/activation-key/activationkey"
  echo "  → Created $BUILD_DIR/activation-key/activationkey  (EDIT THIS)"
fi

# ── 5. Remind user to place the ISO ──────────────────────────────────────────
echo "[5/6] ISO placement check ..."
if [[ -f "$BUILD_DIR/rhel.iso" ]]; then
  echo "  → ISO already present at $BUILD_DIR/rhel.iso"
  # Verify it is s390x
  ISO_LABEL=$(blkid -s LABEL -o value "$BUILD_DIR/rhel.iso" 2>/dev/null || true)
  if [[ "$ISO_LABEL" == *"s390x"* ]]; then
    echo "  → ISO label '$ISO_LABEL' — s390x confirmed ✓"
  else
    echo "  WARNING: ISO label='$ISO_LABEL' does not contain 's390x' — wrong ISO?"
  fi
else
  echo "  → ISO NOT found. Place the RHEL 10.2 s390x DVD ISO at:"
  echo "       $BUILD_DIR/rhel.iso"
  echo "    Download from: https://access.redhat.com/downloads (rhel-10.2-s390x-dvd.iso)"
  echo "    Or rsync from another host:"
  echo "       rsync -P user@host:/path/to/rhel-10.2-s390x-dvd.iso $BUILD_DIR/rhel.iso"
fi

# ── 6. Clone the repo ─────────────────────────────────────────────────────────
echo "[6/6] Repository ..."
if [[ -d "$BUILD_DIR/source/.git" ]]; then
  echo "  → Repo already cloned at $BUILD_DIR/source"
  echo "    To update: cd $BUILD_DIR/source && git pull"
else
  echo "  → Repo not found at $BUILD_DIR/source"
  echo "    Clone it with:"
  echo "       git clone -b enable-support-s390x-podvm-build \\"
  echo "         https://github.com/rafsal-rahim/coco-podvm-scripts.git \\"
  echo "         $BUILD_DIR/source"
fi

echo ""
echo "========================================================"
echo " Setup complete."
echo ""
echo " NEXT STEPS:"
echo "  1. Edit activation-key files:"
echo "       echo 'YOUR_ORG_ID'    > $BUILD_DIR/activation-key/org"
echo "       echo 'YOUR_ACT_KEY'   > $BUILD_DIR/activation-key/activationkey"
echo ""
echo "  2. Place the ISO:"
echo "       $BUILD_DIR/rhel.iso   (rhel-10.2-s390x-dvd.iso)"
echo ""
echo "  3. Clone the repo:"
echo "       git clone -b enable-support-s390x-podvm-build \\"
echo "         https://github.com/rafsal-rahim/coco-podvm-scripts.git \\"
echo "         $BUILD_DIR/source"
echo ""
echo "  4. Run the build:"
echo "       bash /home/builder/source/docs/s390x-build-on-x86/local-pipeline-sim/run-build.sh"
echo "========================================================"
