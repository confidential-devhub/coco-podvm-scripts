#!/bin/bash
set -euo pipefail



echo "Waiting for multi-NIC setup to complete..."

# Wait for eth1 to exist in podns AND have a default route
MAX_WAIT=30
for i in $(seq 1 $MAX_WAIT); do
    # Check if eth1 exists in podns
    if ip netns exec podns ip link show eth1 &>/dev/null; then
        # Check if eth1 has a default route
        if ip netns exec podns ip route show default | grep -q "dev eth1"; then
            echo "✓ eth1 found with default route (multi-NIC setup complete)"
            sleep 2  # Extra safety margin
            break
        fi
    fi
    
    if [ $i -eq $MAX_WAIT ]; then
        echo "WARNING: Multi-NIC setup incomplete after ${MAX_WAIT}s"
        echo "Current routes in podns:"
        ip netns exec podns ip route show || true
    fi
    sleep 1
done


echo "Continuing with bridge setup"


# Static bridge topology for direct VM-to-container communication
# Server host bridge IP: 192.168.0.50
# Server container bridge IP: 192.168.0.100
# Remote client VM/container IPs are learned from aa.toml when present.
# SERVER_HOST_BRIDGE_IP="172.16.0.50"
# SERVER_CONTAINER_BRIDGE_IP="172.16.0.100"
# BRIDGE_SUBNET="172.16.0.0/24"


# AA_CONFIG_FILE="/run/peerpod/aa.toml"

# Get VM's dynamic IP from eth0
VM_IP=$(ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
echo "Detected VM IP: $VM_IP"

# # Read hostname, ports, and Azure credentials from aa.toml if present
# HOSTNAME=""
# PORTS=()


# if [ -f "$AA_CONFIG_FILE" ]; then
#     # Extract hostname
#     HOSTNAME=$(sed -n 's/^[[:space:]]*hostname[[:space:]]*=[[:space:]]*["'\'']\{0,1\}\([^"'\'']*\)["'\'']\{0,1\}[[:space:]]*$/\1/p' "$AA_CONFIG_FILE" | head -n1 | tr -d '[:space:]')
    
#     # Extract ports (supports both single port and array format)
#     # Format: ports = [8080, 8081, 8082] or ports = 8080
#     PORTS_LINE=$(sed -n 's/^[[:space:]]*ports[[:space:]]*=[[:space:]]*\(.*\)$/\1/p' "$AA_CONFIG_FILE" | head -n1)
#     if [ -n "$PORTS_LINE" ]; then
#         # Remove brackets, quotes, and split by comma
#         PORTS_CLEAN=$(echo "$PORTS_LINE" | tr -d '[]"'\''' | tr ',' ' ')
#         read -ra PORTS <<< "$PORTS_CLEAN"
#         echo "Ports found in aa.toml: ${PORTS[*]}"
#     fi
    

    
#     if [ -n "$HOSTNAME" ]; then
#         echo "Hostname found in aa.toml: $HOSTNAME"
        
#         # Set the system hostname permanently first
#         echo "Setting system hostname..."
#         if hostnamectl set-hostname "$HOSTNAME"; then
#             echo "✓ System hostname set to: $HOSTNAME"
            
#             # Verify hostname configuration
#             echo "Verifying hostname configuration:"
#             echo "  hostname: $(hostname)"
#             echo "  hostname -f: $(hostname -f 2>/dev/null || echo 'N/A')"
#         else
#             echo "Warning: Failed to set system hostname"
#         fi
        
#         # Configure hostname via DHCP using nmcli
#         echo "Configuring hostname via DHCP..."
#         CONNECTION_NAME="Wired connection 1"
        
#         # Check if connection exists
#         if nmcli connection show "$CONNECTION_NAME" &>/dev/null; then
#             echo "Found connection: $CONNECTION_NAME"
            
#             # Configure DHCP to send hostname
#             echo "Modifying connection to send hostname via DHCP..."
#             if nmcli connection modify "$CONNECTION_NAME" \
#                 ipv4.dhcp-send-hostname yes \
#                 ipv4.dhcp-hostname "$HOSTNAME"; then
#                 echo "✓ Configured DHCP to send hostname: $HOSTNAME"
                
#                 # Apply changes by restarting the connection
#                 echo "Applying network configuration changes..."
#                 if nmcli connection down "$CONNECTION_NAME" && nmcli connection up "$CONNECTION_NAME"; then
#                     echo "✓ Network connection restarted"
                    
#                     # Wait a moment for DHCP to complete
#                     sleep 2
                    
#                     # Verify the configuration
#                     echo "Verifying DHCP hostname configuration:"
#                     nmcli connection show "$CONNECTION_NAME" | grep "dhcp-hostname" || true
#                 else
#                     echo "Warning: Failed to restart network connection"
#                 fi
#             else
#                 echo "ERROR: Failed to configure DHCP hostname via nmcli"
#             fi
#         else
#             echo "Warning: Connection '$CONNECTION_NAME' not found"
#             echo "Available connections:"
#             nmcli connection show
#         fi
        
#         # Add hostname to /etc/hosts mapping to VM IP
#         if ! grep -q "^${VM_IP}[[:space:]].*${HOSTNAME}" /etc/hosts; then
#             echo "${VM_IP} ${HOSTNAME}" >> /etc/hosts
#             echo "✓ Added hostname mapping to /etc/hosts: ${VM_IP} ${HOSTNAME}"
#         else
#             echo "Hostname mapping already exists in /etc/hosts"
#         fi
        
#         echo "Hostname configuration completed (skipping Azure DNS zone registration)"
#     else
#         echo "No hostname found in aa.toml"
#     fi
# else
#     echo "aa.toml not found at $AA_CONFIG_FILE"
# fi

# # If no ports specified, default to 8080 for backward compatibility
# if [ ${#PORTS[@]} -eq 0 ]; then
#     echo "No ports found in aa.toml, using default port 8080"
#     PORTS=(8080)
# fi


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

# Read hostname and ports from pod annotations in config.json
# Expected pod annotations: bridge.hostname and bridge.ports (e.g. "8000,5201,5202")
HOSTNAME=""
PORTS=()

if [ -n "$CONFIG_JSON" ] && [ -f "$CONFIG_JSON" ]; then
    HOSTNAME=$(grep -o '"bridge\.hostname":"[^"]*"' "$CONFIG_JSON" \
        | sed 's/"bridge\.hostname":"//;s/"$//' | head -n1)

    PORTS_RAW=$(grep -o '"bridge\.ports":"[^"]*"' "$CONFIG_JSON" \
        | sed 's/"bridge\.ports":"//;s/"$//' | head -n1)

    if [ -n "$PORTS_RAW" ]; then
        PORTS_CLEAN=$(echo "$PORTS_RAW" | tr ',' ' ')
        read -ra PORTS <<< "$PORTS_CLEAN"
        echo "Ports found in annotations: ${PORTS[*]}"
    fi

    if [ -n "$HOSTNAME" ]; then
        echo "Hostname found in annotations: $HOSTNAME"

        echo "Setting system hostname..."
        if hostnamectl set-hostname "$HOSTNAME"; then
            echo "✓ System hostname set to: $HOSTNAME"
            echo "Verifying hostname configuration:"
            echo "  hostname: $(hostname)"
            echo "  hostname -f: $(hostname -f 2>/dev/null || echo 'N/A')"
        else
            echo "Warning: Failed to set system hostname"
        fi

        echo "Configuring hostname via DHCP..."
        CONNECTION_NAME="Wired connection 1"

        if nmcli connection show "$CONNECTION_NAME" &>/dev/null; then
            echo "Found connection: $CONNECTION_NAME"
            if nmcli connection modify "$CONNECTION_NAME" \
                ipv4.dhcp-send-hostname yes \
                ipv4.dhcp-hostname "$HOSTNAME"; then
                echo "✓ Configured DHCP to send hostname: $HOSTNAME"
                if nmcli connection down "$CONNECTION_NAME" && nmcli connection up "$CONNECTION_NAME"; then
                    echo "✓ Network connection restarted"
                    sleep 2
                    echo "Verifying DHCP hostname configuration:"
                    nmcli connection show "$CONNECTION_NAME" | grep "dhcp-hostname" || true
                else
                    echo "Warning: Failed to restart network connection"
                fi
            else
                echo "ERROR: Failed to configure DHCP hostname via nmcli"
            fi
        else
            echo "Warning: Connection '$CONNECTION_NAME' not found"
            echo "Available connections:"
            nmcli connection show
        fi

        if ! grep -q "^${VM_IP}[[:space:]].*${HOSTNAME}" /etc/hosts; then
            echo "${VM_IP} ${HOSTNAME}" >> /etc/hosts
            echo "✓ Added hostname mapping to /etc/hosts: ${VM_IP} ${HOSTNAME}"
        else
            echo "Hostname mapping already exists in /etc/hosts"
        fi

        echo "Hostname configuration completed"
    else
        echo "No hostname found in annotations"
    fi
else
    echo "kata config.json not found under $KATA_DIR"
fi

# If no ports specified, default to 8080 for backward compatibility
if [ ${#PORTS[@]} -eq 0 ]; then
    echo "No ports found in annotations, using default port 8080"
    PORTS=(8080)
fi

# Wait for kata-agent and container to start (max 60s)
echo "Waiting for container to start..."
for i in {1..60}; do
    if ip netns list | grep -q podns; then
        echo "podns namespace found"
        break
    fi
    sleep 1
done

# Wait for container to get IP (max 30s)
for i in {1..30}; do
    CONTAINER_IP=$(ip netns exec podns ip -4 addr show eth0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' || echo "")
    if [ -n "$CONTAINER_IP" ]; then
        echo "Container IP detected: $CONTAINER_IP"
        break
    fi
    sleep 1
done

if [ -z "$CONTAINER_IP" ]; then
    echo "ERROR: Could not detect container IP"
    exit 1
fi

# ── shortcut veth configuration ───────────────────────────────────────────────
IFACE="eth0"
HOST_VETH="veth-shortcut"
POD_VETH="veth-shortcut-p"
HOST_IP="10.200.0.1/30"
POD_IP="10.200.0.2/30"
POD_NS="podns"
SUBNET_CIDR="192.168.0.0/24"

# Strip prefix length from a CIDR (10.200.0.1/30 → 10.200.0.1)
strip_prefix() { echo "${1%%/*}"; }
HOST_ADDR() { strip_prefix "$HOST_IP"; }
POD_ADDR()  { strip_prefix "$POD_IP";  }

# Helper: add an iptables rule only when it isn't already present
ipt_add() {
    local table="$1"; shift
    local chain="$1"; shift
    if ! iptables -t "$table" -C "$chain" "$@" 2>/dev/null; then
        iptables -t "$table" -A "$chain" "$@"
    fi
}

# ── 1. sysctl ─────────────────────────────────────────────────────────────────
echo "Applying sysctl settings..."
sysctl -qw net.ipv4.ip_forward=1
sysctl -qw "net.ipv4.conf.${IFACE}.rp_filter=2"
sysctl -qw net.ipv4.conf.all.rp_filter=2

# ── 2. veth pair ──────────────────────────────────────────────────────────────
echo "Creating veth pair ${HOST_VETH} <-> ${POD_VETH}..."
ip link add "$HOST_VETH" type veth peer name "$POD_VETH"
ip link set "$POD_VETH" netns "$POD_NS"

# ── 3. host-side veth address + link ─────────────────────────────────────────
if ! ip addr show "$HOST_VETH" 2>/dev/null | grep -qF "$HOST_IP"; then
    echo "Assigning ${HOST_IP} to ${HOST_VETH}..."
    ip addr add "$HOST_IP" dev "$HOST_VETH"
fi
ip link set "$HOST_VETH" up
sysctl -qw "net.ipv4.conf.${HOST_VETH}.rp_filter=2"

# ── 4. pod-side veth address + link ──────────────────────────────────────────
if ! ip netns exec "$POD_NS" ip addr show "$POD_VETH" 2>/dev/null | grep -qF "$POD_IP"; then
    echo "Assigning ${POD_IP} to ${POD_VETH} inside ${POD_NS}..."
    ip netns exec "$POD_NS" ip addr add "$POD_IP" dev "$POD_VETH"
fi
ip netns exec "$POD_NS" ip link set "$POD_VETH" up
ip netns exec "$POD_NS" sysctl -qw "net.ipv4.conf.${POD_VETH}.rp_filter=2"

# ── 5. pod-side route ─────────────────────────────────────────────────────────
if ! ip netns exec "$POD_NS" ip route show | grep -qF "$SUBNET_CIDR"; then
    echo "Adding route ${SUBNET_CIDR} via $(HOST_ADDR) in ${POD_NS}..."
    ip netns exec "$POD_NS" ip route add "$SUBNET_CIDR" via "$(HOST_ADDR)" dev "$POD_VETH"
fi

# ── 6. iptables rules ─────────────────────────────────────────────────────────
echo "Ensuring iptables POSTROUTING masquerade..."
ipt_add nat POSTROUTING -o "$IFACE" -p tcp -d "$SUBNET_CIDR" -j MASQUERADE

echo "Ensuring iptables FORWARD base rules..."
ipt_add filter FORWARD -i "$HOST_VETH" -o "$IFACE" -j ACCEPT
ipt_add filter FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT

echo "Configuring iptables for ports: ${PORTS[*]}"
for port in "${PORTS[@]}"; do
    port=$(echo "$port" | xargs)
    echo "Ensuring iptables rules for port ${port}..."
    ipt_add nat PREROUTING  -i "$IFACE"     -p tcp --dport "$port" \
        -j DNAT --to-destination "$(POD_ADDR):${port}"
    ipt_add nat POSTROUTING -o "$HOST_VETH" -p tcp -d "$(POD_ADDR)" --dport "$port" \
        -j SNAT --to-source "$(HOST_ADDR)"
    ipt_add filter FORWARD  -o "$HOST_VETH" -p tcp -d "$(POD_ADDR)" --dport "$port" \
        -j ACCEPT
done

# ── 7. persist sysctl across reboots ─────────────────────────────────────────
SYSCTL_FILE="/etc/sysctl.d/99-podvm-forward.conf"
echo "Writing ${SYSCTL_FILE}..."
cat > "$SYSCTL_FILE" <<EOF
net.ipv4.ip_forward=1
net.ipv4.conf.${IFACE}.rp_filter=2
net.ipv4.conf.${HOST_VETH}.rp_filter=2
net.ipv4.conf.all.rp_filter=2
EOF

echo "Azure bridge setup completed successfully"
echo "VM IP: $VM_IP"
echo "Host veth IP: $HOST_IP (${HOST_VETH})"
echo "Pod veth IP:  $POD_IP (${POD_VETH})"
echo "Pod subnet:   $SUBNET_CIDR"
echo "Exposed ports: ${PORTS[*]}"

# # Check if already configured
# if ip netns exec podns ip link show eth2 &>/dev/null; then
#     echo "Bridge already configured, skipping setup"
#     exit 0
# fi

# # Create veth pair in podns namespace
# echo "Creating veth pair..."
# ip netns exec podns ip link add eth2 type veth peer name veth-azure || true
# ip netns exec podns ip link set eth2 up
# ip netns exec podns ip link set veth-azure netns 1

# # Create bridge in host namespace
# echo "Creating bridge..."
# ip link add br-azure type bridge 2>/dev/null || true
# ip link set veth-azure master br-azure 2>/dev/null || true
# ip link set veth-azure up
# ip link set br-azure up

# # Configure static bridge IPs
# echo "Configuring static server bridge addresses..."
# ip addr flush dev br-azure 2>/dev/null || true
# ip addr add ${SERVER_HOST_BRIDGE_IP}/24 dev br-azure 2>/dev/null || true

# ip netns exec podns ip addr flush dev eth2 2>/dev/null || true
# ip netns exec podns ip addr add ${SERVER_CONTAINER_BRIDGE_IP}/24 dev eth2
# echo "Server container bridge IP: $SERVER_CONTAINER_BRIDGE_IP"
# echo "Server host bridge IP: $SERVER_HOST_BRIDGE_IP"

# # Configure routing
# echo "Configuring routes..."
# ip netns exec podns ip route add ${BRIDGE_SUBNET} dev eth2 2>/dev/null || true
# ip route add ${SERVER_CONTAINER_BRIDGE_IP}/32 dev br-azure 2>/dev/null || true
# ip route del ${BRIDGE_SUBNET} dev br-azure 2>/dev/null || true

# # Configure policy-based routing for bridge traffic replies
# echo "Configuring policy-based routing for bridge traffic..."
# # Traffic from bridge IP must use bridge interface for replies
# ip netns exec podns ip rule add from ${SERVER_CONTAINER_BRIDGE_IP} table 100 priority 100 2>/dev/null || true
# ip netns exec podns ip route add default via ${SERVER_HOST_BRIDGE_IP} dev eth2 table 100 2>/dev/null || true
# echo "✓ Bridge traffic from ${SERVER_CONTAINER_BRIDGE_IP} will reply via eth2"

# # Enable proxy ARP and forwarding
# echo "Enabling proxy ARP and forwarding..."
# sysctl -w net.ipv4.conf.all.proxy_arp=1
# sysctl -w net.ipv4.conf.br-azure.proxy_arp=1
# sysctl -w net.ipv4.ip_forward=1

# # Configure iptables for forwarding
# echo "Configuring server iptables forwarding rules..."
# if ! iptables -C FORWARD -i br-azure -o eth0 -j ACCEPT 2>/dev/null; then
#     iptables -I FORWARD -i br-azure -o eth0 -j ACCEPT
# fi

# if ! iptables -C FORWARD -i eth0 -o br-azure -j ACCEPT 2>/dev/null; then
#     iptables -I FORWARD -i eth0 -o br-azure -j ACCEPT
# fi

# # Allow forwarding from eth1 (secondary NIC) to bridge
# if ! iptables -C FORWARD -i br-azure -o eth1 -j ACCEPT 2>/dev/null; then
#     iptables -I FORWARD -i br-azure -o eth1 -j ACCEPT
# fi

# if ! iptables -C FORWARD -i eth1 -o br-azure -j ACCEPT 2>/dev/null; then
#     iptables -I FORWARD -i eth1 -o br-azure -j ACCEPT
# fi

# # Configure iptables DNAT rules for all ports
# echo "Configuring iptables for ports: ${PORTS[*]}"
# for PORT in "${PORTS[@]}"; do
#     # Trim whitespace
#     PORT=$(echo "$PORT" | xargs)
    
#     echo "Setting up iptables rules for port $PORT..."
    
#     # VM IP -> Server container bridge IP
#     if ! iptables -t nat -C PREROUTING -d ${VM_IP} -p tcp --dport ${PORT} -j DNAT --to-destination ${SERVER_CONTAINER_BRIDGE_IP}:${PORT} 2>/dev/null; then
#         iptables -t nat -A PREROUTING -d ${VM_IP} -p tcp --dport ${PORT} -j DNAT --to-destination ${SERVER_CONTAINER_BRIDGE_IP}:${PORT}
#     fi

#     if ! iptables -t nat -C OUTPUT -d ${VM_IP} -p tcp --dport ${PORT} -j DNAT --to-destination ${SERVER_CONTAINER_BRIDGE_IP}:${PORT} 2>/dev/null; then
#         iptables -t nat -A OUTPUT -d ${VM_IP} -p tcp --dport ${PORT} -j DNAT --to-destination ${SERVER_CONTAINER_BRIDGE_IP}:${PORT}
#     fi

#     # Server container bridge IP -> Container IP
#     if ! iptables -t nat -C PREROUTING -d ${SERVER_CONTAINER_BRIDGE_IP} -p tcp --dport ${PORT} -j DNAT --to-destination ${CONTAINER_IP}:${PORT} 2>/dev/null; then
#         iptables -t nat -A PREROUTING -d ${SERVER_CONTAINER_BRIDGE_IP} -p tcp --dport ${PORT} -j DNAT --to-destination ${CONTAINER_IP}:${PORT}
#     fi

#     if ! iptables -t nat -C OUTPUT -d ${SERVER_CONTAINER_BRIDGE_IP} -p tcp --dport ${PORT} -j DNAT --to-destination ${CONTAINER_IP}:${PORT} 2>/dev/null; then
#         iptables -t nat -A OUTPUT -d ${SERVER_CONTAINER_BRIDGE_IP} -p tcp --dport ${PORT} -j DNAT --to-destination ${CONTAINER_IP}:${PORT}
#     fi

#     # MASQUERADE for container traffic
#     if ! iptables -t nat -C POSTROUTING -d ${CONTAINER_IP} -p tcp --dport ${PORT} -j MASQUERADE 2>/dev/null; then
#         iptables -t nat -A POSTROUTING -d ${CONTAINER_IP} -p tcp --dport ${PORT} -j MASQUERADE
#     fi
# done

# echo "Azure bridge setup completed successfully"
# echo "VM IP: $VM_IP"
# echo "Server container bridge IP: $SERVER_CONTAINER_BRIDGE_IP"
# echo "Server host bridge IP: $SERVER_HOST_BRIDGE_IP"
# echo "Container IP: $CONTAINER_IP"
# echo "Bridge subnet: $BRIDGE_SUBNET"
# echo "Exposed ports: ${PORTS[*]}"

