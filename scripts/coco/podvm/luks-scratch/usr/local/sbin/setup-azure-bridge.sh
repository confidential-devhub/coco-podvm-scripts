#!/bin/bash
set -e

echo "Azure bridge role dispatcher starting"

# Discover kata-containers sandbox config from pod annotations
KATA_DIR="/run/kata-containers"
CONFIG_JSON=""

# Wait up to 30s for a config.json that contains the bridge.role annotation.
# Multiple sandbox dirs may exist; only one belongs to the peer-pod container.
MAX_WAIT=30
echo "Waiting for kata sandbox config.json with bridge.role annotation (max ${MAX_WAIT}s)..."
for i in $(seq 1 $MAX_WAIT); do
    for dir in "$KATA_DIR"/*/; do
        dirname=$(basename "$dir")
        if [[ "$dirname" =~ ^[0-9a-f]{64}$ ]] && [ -f "${dir}config.json" ]; then
            if grep -q '"bridge\.role"' "${dir}config.json" 2>/dev/null; then
                CONFIG_JSON="${dir}config.json"
                echo "Using kata config: $CONFIG_JSON (found after ${i}s)"
                break 2
            fi
        fi
    done
    sleep 1
done

if [ -z "$CONFIG_JSON" ]; then
    echo "No kata config.json with bridge.role found under $KATA_DIR after ${MAX_WAIT}s, skipping azure bridge setup"
    exit 0
fi

# Read bridge.role annotation (expected values: "server" or "client")
ROLE=$(grep -o '"bridge\.role":"[^"]*"' "$CONFIG_JSON" \
    | sed 's/"bridge\.role":"//;s/"$//' | head -n1)

if [ -z "$ROLE" ]; then
    echo "No bridge.role annotation found in $CONFIG_JSON, skipping azure bridge setup"
    exit 0
fi

echo "Detected network role from annotations bridge.role: $ROLE"

# Export so child scripts use the same config.json and don't re-scan
export KATA_CONFIG_JSON="$CONFIG_JSON"

case "$ROLE" in
    server)
        /usr/local/sbin/setup-azure-bridge-server.sh
        echo "Bridge setup complete, starting hostname resolution for server..."
        /usr/local/sbin/setup-hostname-resolution-server.sh
        ;;
    client)
        /usr/local/sbin/setup-azure-bridge-client.sh
        echo "Bridge setup complete, starting hostname resolution for client..."
        /usr/local/sbin/setup-hostname-resolution-client.sh
        ;;
    *)
        echo "ERROR: Invalid network role '$ROLE'. Expected 'server' or 'client'."
        exit 1
        ;;
esac
