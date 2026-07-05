#!/bin/bash
set -e


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
# Client host bridge IP: 192.168.0.51
# Client container bridge IP: 192.168.0.101
# Client Bridge Configuration
CLIENT_HOST_BRIDGE_IP="172.16.0.51"
CLIENT_CONTAINER_BRIDGE_IP="172.16.0.101"
BRIDGE_SUBNET="172.16.0.0/24"


AA_CONFIG_FILE="/run/peerpod/aa.toml"

# Get VM's dynamic IP from eth0
VM_IP=$(ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
echo "Detected client VM IP: $VM_IP"

# Read hostname and ports from aa.toml if present
HOSTNAME=""
PORTS=()

if [ -f "$AA_CONFIG_FILE" ]; then
    HOSTNAME=$(sed -n 's/^[[:space:]]*hostname[[:space:]]*=[[:space:]]*["'\'']\{0,1\}\([^"'\'']*\)["'\'']\{0,1\}[[:space:]]*$/\1/p' "$AA_CONFIG_FILE" | head -n1 | tr -d '[:space:]')

    # Extract ports (supports both single port and array format)
    # Format: ports = [8080, 8081, 8082] or ports = 8080
    PORTS_LINE=$(sed -n 's/^[[:space:]]*ports[[:space:]]*=[[:space:]]*\(.*\)$/\1/p' "$AA_CONFIG_FILE" | head -n1)
    if [ -n "$PORTS_LINE" ]; then
        # Remove brackets, quotes, and split by comma
        PORTS_CLEAN=$(echo "$PORTS_LINE" | tr -d '[]"'\''' | tr ',' ' ')
        read -ra PORTS <<< "$PORTS_CLEAN"
        echo "Ports found in aa.toml: ${PORTS[*]}"
    fi

    if [ -n "$HOSTNAME" ]; then
        echo "Hostname found in aa.toml: $HOSTNAME"
        echo "Client will use hostname '$HOSTNAME' to reach server (DNS resolution via network)"
    else
        echo "No hostname found in aa.toml - client will use direct IP addressing"
    fi
else
    echo "aa.toml not found at $AA_CONFIG_FILE"
fi

# If no ports specified, default to 8080 for backward compatibility
if [ ${#PORTS[@]} -eq 0 ]; then
    echo "No ports found in aa.toml, using default port 8080"
    PORTS=(8080)
fi

# Wait for kata-agent/container namespace to exist (max 60s)
echo "Waiting for container namespace to start..."
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

# Check if already configured 

if ip netns exec podns ip link show eth2 &>/dev/null; then
    echo "Bridge already configured, skipping setup"
    exit 0
fi

# Create veth pair in podns namespace
echo "Creating client veth pair..."
ip netns exec podns ip link add eth2 type veth peer name veth-azure || true
ip netns exec podns ip link set eth2 up
ip netns exec podns ip link set veth-azure netns 1

# Create bridge in host namespace
echo "Creating client bridge..."
ip link add br-azure type bridge 2>/dev/null || true
ip link set veth-azure master br-azure 2>/dev/null || true
ip link set veth-azure up
ip link set br-azure up

# Set jumbo frame MTU on all bridge interfaces (9000 bytes)
ip link set br-azure mtu 9000
ip link set veth-azure mtu 9000
ip netns exec podns ip link set eth2 mtu 9000

# Configure static bridge IPs
echo "Configuring static client bridge addresses..."
ip addr flush dev br-azure 2>/dev/null || true
ip addr add ${CLIENT_HOST_BRIDGE_IP}/24 dev br-azure 2>/dev/null || true

ip netns exec podns ip addr flush dev eth2 2>/dev/null || true
ip netns exec podns ip addr add ${CLIENT_CONTAINER_BRIDGE_IP}/24 dev eth2
echo "Client container bridge IP: $CLIENT_CONTAINER_BRIDGE_IP"
echo "Client host bridge IP: $CLIENT_HOST_BRIDGE_IP"

# Configure routing
echo "Configuring client routes..."
ip netns exec podns ip route add ${BRIDGE_SUBNET} dev eth2 2>/dev/null || true
ip route add ${CLIENT_CONTAINER_BRIDGE_IP}/32 dev br-azure 2>/dev/null || true
ip route del ${BRIDGE_SUBNET} dev br-azure 2>/dev/null || true

# Configure policy-based routing for bridge traffic replies
echo "Configuring policy-based routing for bridge traffic..."
ip netns exec podns ip rule add from ${CLIENT_CONTAINER_BRIDGE_IP} table 100 priority 100 2>/dev/null || true
ip netns exec podns ip route add default via ${CLIENT_HOST_BRIDGE_IP} dev eth2 table 100 2>/dev/null || true
echo "✓ Bridge traffic from ${CLIENT_CONTAINER_BRIDGE_IP} will reply via eth2"

# Enable proxy ARP and forwarding
echo "Enabling proxy ARP and forwarding..."
sysctl -w net.ipv4.conf.all.proxy_arp=1
sysctl -w net.ipv4.conf.br-azure.proxy_arp=1
sysctl -w net.ipv4.ip_forward=1

# Always apply forwarding and DNAT rules (idempotent -C checks prevent duplicates)
echo "Configuring client iptables forwarding rules..."
if ! iptables -C FORWARD -i br-azure -o eth0 -j ACCEPT 2>/dev/null; then
    iptables -I FORWARD -i br-azure -o eth0 -j ACCEPT
fi

if ! iptables -C FORWARD -i eth0 -o br-azure -j ACCEPT 2>/dev/null; then
    iptables -I FORWARD -i eth0 -o br-azure -j ACCEPT
fi

# Allow forwarding from eth1 (secondary NIC) to bridge
if ! iptables -C FORWARD -i br-azure -o eth1 -j ACCEPT 2>/dev/null; then
    iptables -I FORWARD -i br-azure -o eth1 -j ACCEPT
fi

if ! iptables -C FORWARD -i eth1 -o br-azure -j ACCEPT 2>/dev/null; then
    iptables -I FORWARD -i eth1 -o br-azure -j ACCEPT
fi

# Configure iptables DNAT rules for all ports
echo "Configuring iptables for ports: ${PORTS[*]}"
for PORT in "${PORTS[@]}"; do
    # Trim whitespace
    PORT=$(echo "$PORT" | xargs)

    echo "Setting up iptables rules for port $PORT..."

    # VM IP -> Client container bridge IP
    if ! iptables -t nat -C PREROUTING -d ${VM_IP} -p tcp --dport ${PORT} -j DNAT --to-destination ${CLIENT_CONTAINER_BRIDGE_IP}:${PORT} 2>/dev/null; then
        iptables -t nat -A PREROUTING -d ${VM_IP} -p tcp --dport ${PORT} -j DNAT --to-destination ${CLIENT_CONTAINER_BRIDGE_IP}:${PORT}
    fi

    if ! iptables -t nat -C OUTPUT -d ${VM_IP} -p tcp --dport ${PORT} -j DNAT --to-destination ${CLIENT_CONTAINER_BRIDGE_IP}:${PORT} 2>/dev/null; then
        iptables -t nat -A OUTPUT -d ${VM_IP} -p tcp --dport ${PORT} -j DNAT --to-destination ${CLIENT_CONTAINER_BRIDGE_IP}:${PORT}
    fi

    # Client container bridge IP -> Container IP
    if ! iptables -t nat -C PREROUTING -d ${CLIENT_CONTAINER_BRIDGE_IP} -p tcp --dport ${PORT} -j DNAT --to-destination ${CONTAINER_IP}:${PORT} 2>/dev/null; then
        iptables -t nat -A PREROUTING -d ${CLIENT_CONTAINER_BRIDGE_IP} -p tcp --dport ${PORT} -j DNAT --to-destination ${CONTAINER_IP}:${PORT}
    fi

    if ! iptables -t nat -C OUTPUT -d ${CLIENT_CONTAINER_BRIDGE_IP} -p tcp --dport ${PORT} -j DNAT --to-destination ${CONTAINER_IP}:${PORT} 2>/dev/null; then
        iptables -t nat -A OUTPUT -d ${CLIENT_CONTAINER_BRIDGE_IP} -p tcp --dport ${PORT} -j DNAT --to-destination ${CONTAINER_IP}:${PORT}
    fi

    # MASQUERADE for container traffic
    if ! iptables -t nat -C POSTROUTING -d ${CONTAINER_IP} -p tcp --dport ${PORT} -j MASQUERADE 2>/dev/null; then
        iptables -t nat -A POSTROUTING -d ${CONTAINER_IP} -p tcp --dport ${PORT} -j MASQUERADE
    fi
done

echo "Azure client bridge setup completed successfully"
echo "Client VM IP: $VM_IP"
echo "Client host bridge IP: $CLIENT_HOST_BRIDGE_IP"
echo "Client container bridge IP: $CLIENT_CONTAINER_BRIDGE_IP"
echo "Container IP: $CONTAINER_IP"
echo "Bridge subnet: $BRIDGE_SUBNET"
echo "Exposed ports: ${PORTS[*]}"
