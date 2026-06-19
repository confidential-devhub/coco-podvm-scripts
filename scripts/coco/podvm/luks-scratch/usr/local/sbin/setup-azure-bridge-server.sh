#!/bin/bash
set -e

# Static bridge topology for direct VM-to-container communication
# Server host bridge IP: 192.168.0.50
# Server container bridge IP: 192.168.0.100
# Remote client VM/container IPs are learned from aa.toml when present.
SERVER_HOST_BRIDGE_IP="192.168.0.50"
SERVER_CONTAINER_BRIDGE_IP="192.168.0.100"
BRIDGE_SUBNET="192.168.0.0/24"


AA_CONFIG_FILE="/run/peerpod/aa.toml"

# Get VM's dynamic IP from eth0
VM_IP=$(ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
echo "Detected VM IP: $VM_IP"

# Read hostname, ports, and Azure credentials from aa.toml if present
HOSTNAME=""
PORTS=()


if [ -f "$AA_CONFIG_FILE" ]; then
    # Extract hostname
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
        
        # Set the system hostname permanently first
        echo "Setting system hostname..."
        if hostnamectl set-hostname "$HOSTNAME"; then
            echo "✓ System hostname set to: $HOSTNAME"
            
            # Verify hostname configuration
            echo "Verifying hostname configuration:"
            echo "  hostname: $(hostname)"
            echo "  hostname -f: $(hostname -f 2>/dev/null || echo 'N/A')"
        else
            echo "Warning: Failed to set system hostname"
        fi
        
        # Configure hostname via DHCP using nmcli
        echo "Configuring hostname via DHCP..."
        CONNECTION_NAME="Wired connection 1"
        
        # Check if connection exists
        if nmcli connection show "$CONNECTION_NAME" &>/dev/null; then
            echo "Found connection: $CONNECTION_NAME"
            
            # Configure DHCP to send hostname
            echo "Modifying connection to send hostname via DHCP..."
            if nmcli connection modify "$CONNECTION_NAME" \
                ipv4.dhcp-send-hostname yes \
                ipv4.dhcp-hostname "$HOSTNAME"; then
                echo "✓ Configured DHCP to send hostname: $HOSTNAME"
                
                # Apply changes by restarting the connection
                echo "Applying network configuration changes..."
                if nmcli connection down "$CONNECTION_NAME" && nmcli connection up "$CONNECTION_NAME"; then
                    echo "✓ Network connection restarted"
                    
                    # Wait a moment for DHCP to complete
                    sleep 2
                    
                    # Verify the configuration
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
        
        # Add hostname to /etc/hosts mapping to VM IP
        if ! grep -q "^${VM_IP}[[:space:]].*${HOSTNAME}" /etc/hosts; then
            echo "${VM_IP} ${HOSTNAME}" >> /etc/hosts
            echo "✓ Added hostname mapping to /etc/hosts: ${VM_IP} ${HOSTNAME}"
        else
            echo "Hostname mapping already exists in /etc/hosts"
        fi
        
        echo "Hostname configuration completed (skipping Azure DNS zone registration)"
    else
        echo "No hostname found in aa.toml"
    fi
else
    echo "aa.toml not found at $AA_CONFIG_FILE"
fi

# If no ports specified, default to 8080 for backward compatibility
if [ ${#PORTS[@]} -eq 0 ]; then
    echo "No ports found in aa.toml, using default port 8080"
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

# Check if already configured
if ip netns exec podns ip link show eth1 &>/dev/null; then
    echo "Bridge already configured, skipping setup"
    exit 0
fi

# Create veth pair in podns namespace
echo "Creating veth pair..."
ip netns exec podns ip link add eth1 type veth peer name veth-azure || true
ip netns exec podns ip link set eth1 up
ip netns exec podns ip link set veth-azure netns 1

# Create bridge in host namespace
echo "Creating bridge..."
ip link add br-azure type bridge 2>/dev/null || true
ip link set veth-azure master br-azure 2>/dev/null || true
ip link set veth-azure up
ip link set br-azure up

# Configure static bridge IPs
echo "Configuring static server bridge addresses..."
ip addr flush dev br-azure 2>/dev/null || true
ip addr add ${SERVER_HOST_BRIDGE_IP}/24 dev br-azure 2>/dev/null || true

ip netns exec podns ip addr flush dev eth1 2>/dev/null || true
ip netns exec podns ip addr add ${SERVER_CONTAINER_BRIDGE_IP}/24 dev eth1
echo "Server container bridge IP: $SERVER_CONTAINER_BRIDGE_IP"
echo "Server host bridge IP: $SERVER_HOST_BRIDGE_IP"

# Configure routing
echo "Configuring routes..."
ip netns exec podns ip route add ${BRIDGE_SUBNET} dev eth1 2>/dev/null || true
ip route add ${SERVER_CONTAINER_BRIDGE_IP}/32 dev br-azure 2>/dev/null || true
ip route del ${BRIDGE_SUBNET} dev br-azure 2>/dev/null || true

# Enable proxy ARP and forwarding
echo "Enabling proxy ARP and forwarding..."
sysctl -w net.ipv4.conf.all.proxy_arp=1
sysctl -w net.ipv4.conf.br-azure.proxy_arp=1
sysctl -w net.ipv4.ip_forward=1

# Configure iptables DNAT rules for all ports
echo "Configuring iptables for ports: ${PORTS[*]}"
for PORT in "${PORTS[@]}"; do
    # Trim whitespace
    PORT=$(echo "$PORT" | xargs)
    
    echo "Setting up iptables rules for port $PORT..."
    
    # VM IP -> Server container bridge IP
    if ! iptables -t nat -C PREROUTING -d ${VM_IP} -p tcp --dport ${PORT} -j DNAT --to-destination ${SERVER_CONTAINER_BRIDGE_IP}:${PORT} 2>/dev/null; then
        iptables -t nat -A PREROUTING -d ${VM_IP} -p tcp --dport ${PORT} -j DNAT --to-destination ${SERVER_CONTAINER_BRIDGE_IP}:${PORT}
    fi

    if ! iptables -t nat -C OUTPUT -d ${VM_IP} -p tcp --dport ${PORT} -j DNAT --to-destination ${SERVER_CONTAINER_BRIDGE_IP}:${PORT} 2>/dev/null; then
        iptables -t nat -A OUTPUT -d ${VM_IP} -p tcp --dport ${PORT} -j DNAT --to-destination ${SERVER_CONTAINER_BRIDGE_IP}:${PORT}
    fi

    # Server container bridge IP -> Container IP
    if ! iptables -t nat -C PREROUTING -d ${SERVER_CONTAINER_BRIDGE_IP} -p tcp --dport ${PORT} -j DNAT --to-destination ${CONTAINER_IP}:${PORT} 2>/dev/null; then
        iptables -t nat -A PREROUTING -d ${SERVER_CONTAINER_BRIDGE_IP} -p tcp --dport ${PORT} -j DNAT --to-destination ${CONTAINER_IP}:${PORT}
    fi

    if ! iptables -t nat -C OUTPUT -d ${SERVER_CONTAINER_BRIDGE_IP} -p tcp --dport ${PORT} -j DNAT --to-destination ${CONTAINER_IP}:${PORT} 2>/dev/null; then
        iptables -t nat -A OUTPUT -d ${SERVER_CONTAINER_BRIDGE_IP} -p tcp --dport ${PORT} -j DNAT --to-destination ${CONTAINER_IP}:${PORT}
    fi

    # MASQUERADE for container traffic
    if ! iptables -t nat -C POSTROUTING -d ${CONTAINER_IP} -p tcp --dport ${PORT} -j MASQUERADE 2>/dev/null; then
        iptables -t nat -A POSTROUTING -d ${CONTAINER_IP} -p tcp --dport ${PORT} -j MASQUERADE
    fi
done

echo "Azure bridge setup completed successfully"
echo "VM IP: $VM_IP"
echo "Server container bridge IP: $SERVER_CONTAINER_BRIDGE_IP"
echo "Server host bridge IP: $SERVER_HOST_BRIDGE_IP"
echo "Container IP: $CONTAINER_IP"
echo "Bridge subnet: $BRIDGE_SUBNET"
echo "Exposed ports: ${PORTS[*]}"

# Resolve hostname in container namespace (after bridge setup)
# if [ -n "$HOSTNAME" ]; then
#     echo "Resolving hostname in container namespace..."
    
#     # Log ps aux for debugging
#     echo "=== Current processes (ps aux) ==="
#     ps aux
#     echo "=================================="
    
#     # Retry logic for hostname resolution (server resolves first, then client)
#     HOSTNAME_IP=""
#     MAX_RETRIES=10
#     RETRY_DELAY=2
    
#     for attempt in $(seq 1 $MAX_RETRIES); do
#         echo "Attempt $attempt/$MAX_RETRIES: Resolving hostname ${HOSTNAME}..."
#         HOSTNAME_IP=$(curl -v "http://${HOSTNAME}" 2>&1 | grep -oP 'Trying \K[\d.]+' | head -n1)
        
#         if [ -n "$HOSTNAME_IP" ]; then
#             echo "✓ Resolved ${HOSTNAME} to ${HOSTNAME_IP} on attempt $attempt"
#             break
#         else
#             echo "Failed to resolve ${HOSTNAME}, retrying in ${RETRY_DELAY}s..."
#             sleep $RETRY_DELAY
#         fi
#     done
    
#     if [ -n "$HOSTNAME_IP" ]; then
#         echo "Successfully resolved ${HOSTNAME} to ${HOSTNAME_IP}"
        
#         # Find Java process in podns namespace
#         echo "Looking for Java process in podns namespace..."
        
#         # Log processes in podns namespace
#         echo "=== Processes in podns namespace ==="
#         ip netns exec podns ps aux || echo "Failed to list podns processes"
#         echo "===================================="
        
#         # Try to find Java process in podns namespace
#         JAVA_PID=$(ip netns exec podns ps aux | grep -i 'java' | grep -v grep | head -n1 | awk '{print $2}')
        
#         # If Java not found, try sleep infinity
#         if [ -z "$JAVA_PID" ]; then
#             echo "Java process not found, trying 'sleep infinity'..."
#             JAVA_PID=$(ip netns exec podns ps aux | grep 'sleep infinity' | grep -v grep | head -n1 | awk '{print $2}')
#         fi
        
#         # If sleep not found, try pause
#         if [ -z "$JAVA_PID" ]; then
#             echo "Sleep process not found, trying 'pause'..."
#             JAVA_PID=$(ip netns exec podns ps aux | grep '/pause' | grep -v grep | head -n1 | awk '{print $2}')
#         fi
        
#         if [ -n "$JAVA_PID" ]; then
#             echo "Found container process PID: ${JAVA_PID}"
            
#             # Check if hostname already exists in container's /etc/hosts
#             if ! nsenter -t ${JAVA_PID} -a sh -c "grep -q '${HOSTNAME}' /etc/hosts" 2>/dev/null; then
#                 # Add hostname to container's /etc/hosts
#                 nsenter -t ${JAVA_PID} -a sh -c "echo '${HOSTNAME_IP} ${HOSTNAME}' >> /etc/hosts"
#                 echo "✓ Added ${HOSTNAME} -> ${HOSTNAME_IP} to container's /etc/hosts"
#             else
#                 echo "Hostname already exists in container's /etc/hosts"
#             fi
#         else
#             echo "Warning: Container process not found in podns namespace, skipping container /etc/hosts update"
#         fi
#     else
#         echo "Warning: Could not resolve hostname ${HOSTNAME} after $MAX_RETRIES attempts"
#     fi
# fi


