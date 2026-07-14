#!/bin/bash
set -e

# ── Read hostname from kata config.json annotations ───────────────────────────
# Use path exported by the dispatcher if available, otherwise scan for it.
KATA_DIR="/run/kata-containers"
CONFIG_JSON="${KATA_CONFIG_JSON:-}"

VM_IP=$(ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
echo "Detected VM IP: $VM_IP"

if [ -z "$CONFIG_JSON" ]; then
    for dir in "$KATA_DIR"/*/; do
        dirname=$(basename "$dir")
        if [[ "$dirname" =~ ^[0-9a-f]{64}$ ]] && [ -f "${dir}config.json" ]; then
            if grep -q '"bridge\.role"' "${dir}config.json" 2>/dev/null; then
                CONFIG_JSON="${dir}config.json"
                break
            fi
        fi
    done
fi

HOSTNAME=""
if [ -n "$CONFIG_JSON" ] && [ -f "$CONFIG_JSON" ]; then
    HOSTNAME=$(grep -o '"bridge\.hostname":"[^"]*"' "$CONFIG_JSON" \
        | sed 's/"bridge\.hostname":"//;s/"$//' | head -n1)
fi

if [ -z "$HOSTNAME" ]; then
    echo "No hostname found in annotations, skipping hostname resolution"
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
MAX_WAIT=600  # Wait up to 2 minutes

for attempt in $(seq 1 $MAX_WAIT); do
    # Find kata-agent process
    KATA_AGENT_PID=$(ps aux | grep -E 'kata-agent|agent-ctl' | grep -v grep | head -n1 | awk '{print $2}')
    
    if [ -n "$KATA_AGENT_PID" ]; then
        echo "Found kata-agent PID: ${KATA_AGENT_PID} (attempt $attempt)"
        
        # Check if kata-agent has spawned container processes in podns namespace
        # Look for the Kata-Agent-Lock sentinel process
        CONTAINER_PID=$(ip netns exec podns ps aux 2>/dev/null | grep 'Kata-Agent-Lock' | grep -v grep | head -n1 | awk '{print $2}')
        
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

# Resolve hostname using curl (same as server script for consistency)
echo "Resolving hostname using curl..."
HOSTNAME_IP=""
MAX_RETRIES=20
RETRY_DELAY=2

for attempt in $(seq 1 $MAX_RETRIES); do
    echo "Attempt $attempt/$MAX_RETRIES: Resolving hostname ${HOSTNAME}..."
    HOSTNAME_IP=$(curl -v "http://${HOSTNAME}" 2>&1 | grep -oP 'IPv4: \K[\d.]+' | head -n1)
    
    if [ -n "$HOSTNAME_IP" ]; then
        echo "✓ Resolved ${HOSTNAME} to ${HOSTNAME_IP} on attempt $attempt"
        break
    else
        echo "Failed to resolve ${HOSTNAME}, retrying in ${RETRY_DELAY}s..."
        sleep $RETRY_DELAY
    fi
done

if [ -z "$HOSTNAME_IP" ]; then
    echo "Warning: Could not resolve hostname ${HOSTNAME} after $MAX_RETRIES attempts"
    exit 1
fi

echo "Successfully resolved ${HOSTNAME} to ${HOSTNAME_IP}"
echo "Using container process PID: ${CONTAINER_PID}"


# Update /etc/hosts in container
if [ -n "$CONTAINER_PID" ]; then
    if ! nsenter -t ${CONTAINER_PID} -a sh -c "grep -q '${HOSTNAME}' /etc/hosts" 2>/dev/null; then
        nsenter -t ${CONTAINER_PID} -a sh -c "echo '${HOSTNAME_IP} ${HOSTNAME}' >> /etc/hosts"
        echo "✓ Added ${HOSTNAME} -> ${HOSTNAME_IP} to container's /etc/hosts"
    else
        echo "Hostname already exists in container's /etc/hosts"
    fi
fi

echo "Client hostname resolution completed successfully"


SPARK_ENV_DIRS=$(ls -d /run/kata-containers/shared/containers/*-conf/ 2>/dev/null)

if [ -z "$SPARK_ENV_DIRS" ]; then
    echo "Warning: could not locate any *-conf/ dir under /run/kata-containers/shared/containers/"
else
    for SPARK_ENV_DIR in $SPARK_ENV_DIRS; do
        SPARK_ENV_FILE="${SPARK_ENV_DIR%/}/spark-env.sh"
        if [ ! -f "$SPARK_ENV_FILE" ]; then
            echo "Skipping ${SPARK_ENV_DIR} — no spark-env.sh found"
            continue
        fi
        if ! grep -q 'SPARK_WORKER_HOST' "${SPARK_ENV_FILE}" 2>/dev/null; then
            printf '\nexport SPARK_WORKER_HOST=%s\n' "${VM_IP}" >> "${SPARK_ENV_FILE}"
            echo "✓ Set SPARK_WORKER_HOST=${VM_IP} in ${SPARK_ENV_FILE}"
        else
            echo "SPARK_WORKER_HOST already set in ${SPARK_ENV_FILE}"
        fi
    done
fi

nsenter -t ${CONTAINER_PID} -a sh -c "touch /tmp/start"
echo "✓ Written /tmp/start in container (PID ${CONTAINER_PID})"