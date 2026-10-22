#!/bin/bash
# =============================================================================
# update-source.sh — Pull latest code changes into the Fyre VM and optionally
#                    rebuild the builder image.
#
# Use this for the inner development loop:
#   1. Make a change locally
#   2. Push to GitHub
#   3. Run this on the Fyre VM to pull + optionally rebuild
#   4. Run run-build.sh --skip-stage1  (or full run)
#
# Usage:
#   bash update-source.sh           # git pull only
#   bash update-source.sh --rebuild # git pull + podman build
# =============================================================================
set -euo pipefail

SOURCE_DIR=/home/builder/source
BUILD_DIR=/home/builder

REBUILD=0
for arg in "$@"; do
  [[ "$arg" == "--rebuild" ]] && REBUILD=1
done

echo "[1/2] Pulling latest from GitHub ..."
cd "$SOURCE_DIR"
git fetch origin
git reset --hard origin/enable-support-s390x-podvm-build
echo "      → Now at: $(git log --oneline -1)"

if [[ $REBUILD -eq 1 ]]; then
  echo "[2/2] Rebuilding builder-s390x container image ..."
  podman build \
    -v "$BUILD_DIR/activation-key/:/activation-key/:Z" \
    -t builder-s390x \
    -f "$SOURCE_DIR/konflux/Dockerfile.s390x" \
    "$SOURCE_DIR"
  echo "      → builder-s390x rebuilt ✓"
else
  echo "[2/2] Skipping image rebuild (pass --rebuild to force)"
fi

echo ""
echo "Ready. Run the build:"
echo "  bash $SOURCE_DIR/docs/s390x-build-on-x86/local-pipeline-sim/run-build.sh --skip-build"
