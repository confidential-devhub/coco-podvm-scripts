#!/bin/bash
set -e

echo "Azure bridge role dispatcher starting"

# Discover kata-containers sandbox config from pod annotations
KATA_DIR="/run/kata-containers"
CONFIG_JSON=""

# Find the first directory whose name is a 64-char hex string
for dir in "$KATA_DIR"/*/; do
    dirname=$(basename "$dir")
    if [[ "$dirname" =~ ^[0-9a-f]{64}$ ]]; then
        CONFIG_JSON="${dir}config.json"
        echo "Using kata config: $CONFIG_JSON"
        break
    fi
done

if [ -z "$CONFIG_JSON" ] || [ ! -f "$CONFIG_JSON" ]; then
    echo "No kata config.json found under $KATA_DIR, skipping azure bridge setup"
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
# Made with Bob
