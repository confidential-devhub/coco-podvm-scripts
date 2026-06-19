#!/bin/bash
set -e

AA_CONFIG_FILE="/run/peerpod/aa.toml"

echo "Azure bridge role dispatcher starting"

if [ ! -f "$AA_CONFIG_FILE" ]; then
    echo "No aa.toml found at $AA_CONFIG_FILE, skipping azure bridge setup"
    exit 0
fi

ROLE=$(sed -n 's/^[[:space:]]*bridge_role[[:space:]]*=[[:space:]]*["'\'']\{0,1\}\([^"'\'']*\)["'\'']\{0,1\}[[:space:]]*$/\1/p' "$AA_CONFIG_FILE" | head -n1 | tr -d '[:space:]')

if [ -z "$ROLE" ]; then
    echo "No bridge_role key found in $AA_CONFIG_FILE, skipping azure bridge setup"
    exit 0
fi

echo "Detected network role from $AA_CONFIG_FILE bridge_role key: $ROLE"

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
