#!/bin/bash
set -e

AA_CONFIG_FILE="/run/peerpod/aa.toml"

# Read hostname from aa.toml
HOSTNAME=""
if [ -f "$AA_CONFIG_FILE" ]; then
    HOSTNAME=$(sed -n 's/^[[:space:]]*hostname[[:space:]]*=[[:space:]]*["'\'']\{0,1\}\([^"'\'']*\)["'\'']\{0,1\}[[:space:]]*$/\1/p' "$AA_CONFIG_FILE" | head -n1 | tr -d '[:space:]')
fi

if [ -z "$HOSTNAME" ]; then
    echo "No hostname found in aa.toml, skipping hostname resolution"
    exit 0
fi

echo "Resolving hostname in container namespace: ${HOSTNAME}"

# Wait for container namespace to be fully ready
echo "Waiting for container to be fully operational..."
for i in {1..30}; do
    if ip netns exec podns ip link show eth0 &>/dev/null && \
       ip netns exec podns ip link show eth1 &>/dev/null; then
        echo "Container network interfaces ready"
        break
    fi
    sleep 1
done

# Wait for kata-agent to spawn container processes (indicates kata-agent is ready)
echo "Waiting for kata-agent to spawn container processes..."
KATA_AGENT_PID=""
CONTAINER_PID=""
MAX_WAIT=120  # Wait up to 2 minutes

for attempt in $(seq 1 $MAX_WAIT); do
    # Find kata-agent process
    KATA_AGENT_PID=$(ps aux | grep -E 'kata-agent|agent-ctl' | grep -v grep | head -n1 | awk '{print $2}')
    
    if [ -n "$KATA_AGENT_PID" ]; then
        echo "Found kata-agent PID: ${KATA_AGENT_PID} (attempt $attempt)"
        
        # Check if kata-agent has spawned container processes in podns namespace
        # Try Java first
        CONTAINER_PID=$(ip netns exec podns ps aux 2>/dev/null | grep -i 'java' | grep -v grep | head -n1 | awk '{print $2}')
        
        # Try sleep infinity
        if [ -z "$CONTAINER_PID" ]; then
            CONTAINER_PID=$(ip netns exec podns ps aux 2>/dev/null | grep 'sleep infinity' | grep -v grep | head -n1 | awk '{print $2}')
        fi
        
        # Try pause
        if [ -z "$CONTAINER_PID" ]; then
            CONTAINER_PID=$(ip netns exec podns ps aux 2>/dev/null | grep '/pause' | grep -v grep | head -n1 | awk '{print $2}')
        fi
        
        if [ -n "$CONTAINER_PID" ]; then
            echo "✓ Container process found in podns namespace: PID ${CONTAINER_PID}"
            echo "✓ Kata-agent has completed container initialization"
            break
        fi
    fi
    
    if [ $attempt -eq $MAX_WAIT ]; then
        echo "Warning: Container process not spawned by kata-agent after ${MAX_WAIT}s"
        exit 1
    fi
    
    sleep 1
done

# Get hostname IP from /etc/hosts (already set by bridge setup script)
echo "Reading hostname IP from /etc/hosts..."
HOSTNAME_IP=$(grep -E "^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+[[:space:]]+${HOSTNAME}([[:space:]]|$)" /etc/hosts | awk '{print $1}' | head -n1)

if [ -z "$HOSTNAME_IP" ]; then
    echo "Warning: Could not find hostname ${HOSTNAME} in /etc/hosts"
    exit 1
fi

echo "Found ${HOSTNAME} -> ${HOSTNAME_IP} in /etc/hosts"
echo "Using container process PID: ${CONTAINER_PID}"

# Check if hostname already exists in container's /etc/hosts
if ! nsenter -t ${CONTAINER_PID} -a sh -c "grep -q '${HOSTNAME}' /etc/hosts" 2>/dev/null; then
    # Add hostname to container's /etc/hosts
    nsenter -t ${CONTAINER_PID} -a sh -c "echo '${HOSTNAME_IP} ${HOSTNAME}' >> /etc/hosts"
    echo "✓ Added ${HOSTNAME} -> ${HOSTNAME_IP} to container's /etc/hosts"
else
    echo "Hostname already exists in container's /etc/hosts"
fi

echo "Hostname resolution completed successfully"
