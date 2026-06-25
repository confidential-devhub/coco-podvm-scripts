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

# Read hostname from aa.toml if present
# Client only needs hostname - DNS resolution will happen through the network
if [ -f "$AA_CONFIG_FILE" ]; then
    HOSTNAME=$(sed -n 's/^[[:space:]]*hostname[[:space:]]*=[[:space:]]*["'\'']\{0,1\}\([^"'\'']*\)["'\'']\{0,1\}[[:space:]]*$/\1/p' "$AA_CONFIG_FILE" | head -n1 | tr -d '[:space:]')
    
    if [ -n "$HOSTNAME" ]; then
        echo "Hostname found in aa.toml: $HOSTNAME"
        echo "Client will use hostname '$HOSTNAME' to reach server (DNS resolution via network)"
    else
        echo "No hostname found in aa.toml - client will use direct IP addressing"
    fi
else
    echo "aa.toml not found at $AA_CONFIG_FILE"
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

if ! ip netns list | grep -q podns; then
    echo "ERROR: podns namespace not found"
    exit 1
fi

# Check if already configured
if ip netns exec podns ip link show eth2 &>/dev/null; then
    echo "Client bridge already configured, skipping setup"
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

# Configure static bridge IPs
echo "Configuring static client bridge addresses..."
ip addr flush dev br-azure 2>/dev/null || true
ip addr add ${CLIENT_HOST_BRIDGE_IP}/24 dev br-azure 2>/dev/null || true

ip netns exec podns ip addr flush dev eth2 2>/dev/null || true
ip netns exec podns ip addr add ${CLIENT_CONTAINER_BRIDGE_IP}/24 dev eth2
echo "Client container bridge IP: $CLIENT_CONTAINER_BRIDGE_IP"
echo "Client host bridge IP: $CLIENT_HOST_BRIDGE_IP"

# Configure routing exactly per documented setup
echo "Configuring client routes..."
ip netns exec podns ip route add ${BRIDGE_SUBNET} dev eth2 2>/dev/null || true
ip route add ${CLIENT_CONTAINER_BRIDGE_IP}/32 dev br-azure 2>/dev/null || true
ip route del ${BRIDGE_SUBNET} dev br-azure 2>/dev/null || true

# Configure policy-based routing for bridge traffic replies
echo "Configuring policy-based routing for bridge traffic..."
# Traffic from bridge IP must use bridge interface for replies
ip netns exec podns ip rule add from ${CLIENT_CONTAINER_BRIDGE_IP} table 100 priority 100 2>/dev/null || true
ip netns exec podns ip route add default via ${CLIENT_HOST_BRIDGE_IP} dev eth2 table 100 2>/dev/null || true
echo "✓ Bridge traffic from ${CLIENT_CONTAINER_BRIDGE_IP} will reply via eth2"

# Enable proxy ARP and forwarding
echo "Enabling proxy ARP and forwarding..."
sysctl -w net.ipv4.conf.all.proxy_arp=1
sysctl -w net.ipv4.conf.br-azure.proxy_arp=1
sysctl -w net.ipv4.ip_forward=1

# Configure iptables for forwarding and outbound masquerade
echo "Configuring client iptables..."
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

if ! iptables -t nat -C POSTROUTING -s ${CLIENT_CONTAINER_BRIDGE_IP}/32 -o eth0 -j MASQUERADE 2>/dev/null; then
    iptables -t nat -A POSTROUTING -s ${CLIENT_CONTAINER_BRIDGE_IP}/32 -o eth0 -j MASQUERADE
fi

echo "Azure client bridge setup completed successfully"
echo "Client VM IP: $VM_IP"
echo "Client host bridge IP: $CLIENT_HOST_BRIDGE_IP"
echo "Client container bridge IP: $CLIENT_CONTAINER_BRIDGE_IP"
echo "Bridge subnet: $BRIDGE_SUBNET"

