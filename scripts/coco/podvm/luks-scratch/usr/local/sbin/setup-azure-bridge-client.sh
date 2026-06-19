#!/bin/bash
set -e

# Static bridge topology for direct VM-to-container communication
# Client host bridge IP: 192.168.0.51
# Client container bridge IP: 192.168.0.101
CLIENT_HOST_BRIDGE_IP="192.168.0.51"
CLIENT_CONTAINER_BRIDGE_IP="192.168.0.101"
BRIDGE_SUBNET="192.168.0.0/24"

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
if ip netns exec podns ip link show eth1 &>/dev/null; then
    echo "Client bridge already configured, skipping setup"
    exit 0
fi

# Create veth pair in podns namespace
echo "Creating client veth pair..."
ip netns exec podns ip link add eth1 type veth peer name veth-azure || true
ip netns exec podns ip link set eth1 up
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

ip netns exec podns ip addr flush dev eth1 2>/dev/null || true
ip netns exec podns ip addr add ${CLIENT_CONTAINER_BRIDGE_IP}/24 dev eth1
echo "Client container bridge IP: $CLIENT_CONTAINER_BRIDGE_IP"
echo "Client host bridge IP: $CLIENT_HOST_BRIDGE_IP"

# Configure routing exactly per documented setup
echo "Configuring client routes..."
ip netns exec podns ip route add ${BRIDGE_SUBNET} dev eth1 2>/dev/null || true
ip route add ${CLIENT_CONTAINER_BRIDGE_IP}/32 dev br-azure 2>/dev/null || true
ip route del ${BRIDGE_SUBNET} dev br-azure 2>/dev/null || true

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

if ! iptables -t nat -C POSTROUTING -s ${CLIENT_CONTAINER_BRIDGE_IP}/32 -o eth0 -j MASQUERADE 2>/dev/null; then
    iptables -t nat -A POSTROUTING -s ${CLIENT_CONTAINER_BRIDGE_IP}/32 -o eth0 -j MASQUERADE
fi

echo "Azure client bridge setup completed successfully"
echo "Client VM IP: $VM_IP"
echo "Client host bridge IP: $CLIENT_HOST_BRIDGE_IP"
echo "Client container bridge IP: $CLIENT_CONTAINER_BRIDGE_IP"
echo "Bridge subnet: $BRIDGE_SUBNET"

# Resolve hostname in container namespace (after bridge setup)
# if [ -n "$HOSTNAME" ]; then
#     echo "Resolving hostname in container namespace..."
    
#     # Log ps aux for debugging
#     echo "=== Current processes (ps aux) ==="
#     ps aux
#     echo "=================================="
    
#     # Get the hostname's IP using getent (works at VM level)
#     HOSTNAME_IP=$(getent hosts "${HOSTNAME}" | awk '{print $1}' | head -n1)
    
#     if [ -n "$HOSTNAME_IP" ]; then
#         echo "Resolved ${HOSTNAME} to ${HOSTNAME_IP}"
        
#         # Find container process in podns namespace with retry logic
#         echo "Looking for container process in podns namespace..."
        
#         # Log processes in podns namespace
#         echo "=== Processes in podns namespace ==="
#         ip netns exec podns ps aux || echo "Failed to list podns processes"
#         echo "===================================="
        
#         CONTAINER_PID=""
#         MAX_WAIT=90  # Wait up to 90 seconds
        
#         for attempt in $(seq 1 $MAX_WAIT); do
#             # Try Java first
#             CONTAINER_PID=$(ip netns exec podns ps aux 2>/dev/null | grep -i 'java' | grep -v grep | head -n1 | awk '{print $2}')
            
#             # Try sleep infinity
#             if [ -z "$CONTAINER_PID" ]; then
#                 CONTAINER_PID=$(ip netns exec podns ps aux 2>/dev/null | grep 'sleep infinity' | grep -v grep | head -n1 | awk '{print $2}')
#             fi
            
#             # Try pause
#             if [ -z "$CONTAINER_PID" ]; then
#                 CONTAINER_PID=$(ip netns exec podns ps aux 2>/dev/null | grep '/pause' | grep -v grep | head -n1 | awk '{print $2}')
#             fi
            
#             if [ -n "$CONTAINER_PID" ]; then
#                 echo "✓ Found container process PID: ${CONTAINER_PID} (attempt $attempt)"
#                 break
#             fi
            
#             if [ $attempt -eq $MAX_WAIT ]; then
#                 echo "Warning: Container process not found after ${MAX_WAIT}s, skipping /etc/hosts update"
#                 exit 0  # Exit successfully - bridge is configured
#             fi
            
#             sleep 1
#         done
        
#         # Now update /etc/hosts if we found the process
#         if [ -n "$CONTAINER_PID" ]; then
#             if ! nsenter -t ${CONTAINER_PID} -a sh -c "grep -q '${HOSTNAME}' /etc/hosts" 2>/dev/null; then
#                 nsenter -t ${CONTAINER_PID} -a sh -c "echo '${HOSTNAME_IP} ${HOSTNAME}' >> /etc/hosts"
#                 echo "✓ Added ${HOSTNAME} -> ${HOSTNAME_IP} to container's /etc/hosts"
#             else
#                 echo "Hostname already exists in container's /etc/hosts"
#             fi
#         fi
#     else
#         echo "Warning: Could not resolve hostname ${HOSTNAME}"
#     fi
# fi

