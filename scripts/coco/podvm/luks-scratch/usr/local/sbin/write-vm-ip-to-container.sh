# # NOT IN USE CURRENTLY!

# #!/bin/bash
# set -e

# # Get this VM's IP from eth0
# VM_IP=$(ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')

# if [ -z "$VM_IP" ]; then
#     echo "ERROR: Could not detect VM IP from eth0"
#     exit 1
# fi

# echo "Detected VM IP: ${VM_IP}"

# # Wait for container network interfaces to be ready
# echo "Waiting for container to be fully operational..."
# for i in {1..30}; do
#     if ip netns exec podns ip link show eth0 &>/dev/null && \
#        ip netns exec podns ip link show eth1 &>/dev/null; then
#         echo "Container network interfaces ready"
#         break
#     fi
#     sleep 1
# done

# # Wait for container process to appear
# echo "Waiting for container process..."
# CONTAINER_PID=""
# MAX_WAIT=200  # Wait up to 2 minutes

# for attempt in $(seq 1 $MAX_WAIT); do
#     # Find container process by time sleep 60 entrypoint
#     CONTAINER_PID=$(ip netns exec podns ps aux 2>/dev/null | grep -F 'Kata-Agent-Lock' | grep -v grep | head -n1 | awk '{print $2}')

#     if [ -n "$CONTAINER_PID" ]; then
#         echo "✓ Container process found in podns namespace: PID ${CONTAINER_PID} (attempt $attempt)"
#         break
#     fi

#     if [ $attempt -eq $MAX_WAIT ]; then
#         echo "Warning: Container process not found after ${MAX_WAIT}s"
#         exit 1
#     fi

#     sleep 1
# done

# echo "Using container process PID: ${CONTAINER_PID}"

# nsenter -t ${CONTAINER_PID} -a sh -c "printf '\n%s' 'export SPARK_LOCAL_IP=${VM_IP}' >> /opt/ibm/spark/conf/spark-env.sh"
# nsenter -t ${CONTAINER_PID} -a sh -c "printf '\n%s' 'export SPARK_PUBLIC_DNS=${VM_IP}' >> /opt/ibm/spark/conf/spark-env.sh"

# # Write VM IP to /tmp/start inside the container filesystem (create if not exists)
# nsenter -t ${CONTAINER_PID} -a sh -c "touch /tmp/start"
# echo "✓ Written /tmp/start in container (PID ${CONTAINER_PID})"

# echo "VM IP injection completed successfully"

