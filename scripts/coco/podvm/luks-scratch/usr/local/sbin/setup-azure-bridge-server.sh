#!/bin/bash
set -euo pipefail

# ── Wait for multi-NIC setup ──────────────────────────────────────────────────
echo "Waiting for multi-NIC setup to complete..."
MAX_WAIT=30
for i in $(seq 1 $MAX_WAIT); do
    if ip netns exec podns ip link show eth1 &>/dev/null; then
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

# ── Get VM IP ─────────────────────────────────────────────────────────────────
VM_IP=$(ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
echo "Detected VM IP: $VM_IP"

# ── Read annotations from kata config.json ───────────────────────────────────
# Use path exported by the dispatcher if available, otherwise scan for it.
KATA_DIR="/run/kata-containers"
CONFIG_JSON="${KATA_CONFIG_JSON:-}"

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
echo "Using kata config: $CONFIG_JSON"

HOSTNAME=""
PORTS=()

if [ -n "$CONFIG_JSON" ] && [ -f "$CONFIG_JSON" ]; then
    HOSTNAME=$(grep -o '"bridge\.hostname":"[^"]*"' "$CONFIG_JSON" \
        | sed 's/"bridge\.hostname":"//;s/"$//' | head -n1)

    PORTS_RAW=$(grep -o '"bridge\.ports":"[^"]*"' "$CONFIG_JSON" \
        | sed 's/"bridge\.ports":"//;s/"$//' | head -n1)

    if [ -n "$PORTS_RAW" ]; then
        read -ra PORTS <<< "$(echo "$PORTS_RAW" | tr ',' ' ')"
        echo "Ports found in annotations: ${PORTS[*]}"
    fi

    if [ -n "$HOSTNAME" ]; then
        echo "Hostname found in annotations: $HOSTNAME"

        echo "Setting system hostname..."
        if hostnamectl set-hostname "$HOSTNAME"; then
            echo "✓ System hostname set to: $HOSTNAME"
            echo "  hostname:   $(hostname)"
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
                    nmcli connection show "$CONNECTION_NAME" | grep "dhcp-hostname" || true
                else
                    echo "Warning: Failed to restart network connection"
                fi
            else
                echo "ERROR: Failed to configure DHCP hostname via nmcli"
            fi
        else
            echo "Warning: Connection '$CONNECTION_NAME' not found"
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

if [ ${#PORTS[@]} -eq 0 ]; then
    echo "No ports found in annotations, using default port 8080"
    PORTS=(8080)
fi

# ── Wait for podns namespace ──────────────────────────────────────────────────
echo "Waiting for container to start..."
for i in {1..60}; do
    if ip netns list | grep -q podns; then
        echo "podns namespace found"
        break
    fi
    sleep 1
done

# ── Wait for container IP ─────────────────────────────────────────────────────
for i in {1..30}; do
    CONTAINER_IP=$(ip netns exec podns ip -4 addr show eth0 2>/dev/null \
        | grep -oP '(?<=inet\s)\d+(\.\d+){3}' || echo "")
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

# ── Network configuration ─────────────────────────────────────────────────────
IFACE="eth0"
HOST_VETH="veth-shortcut"
POD_VETH="veth-shortcut-p"
HOST_IP="10.200.0.1/30"
POD_IP="10.200.0.2/30"
POD_NS="podns"
SUBNET_CIDR="192.168.0.0/24"

strip_prefix() { echo "${1%%/*}"; }
HOST_ADDR() { strip_prefix "$HOST_IP"; }
POD_ADDR()  { strip_prefix "$POD_IP";  }

# Add an iptables rule only when it isn't already present
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

# ── 3. host-side veth ────────────────────────────────────────────────────────
if ! ip addr show "$HOST_VETH" 2>/dev/null | grep -qF "$HOST_IP"; then
    echo "Assigning ${HOST_IP} to ${HOST_VETH}..."
    ip addr add "$HOST_IP" dev "$HOST_VETH"
fi
ip link set "$HOST_VETH" up
sysctl -qw "net.ipv4.conf.${HOST_VETH}.rp_filter=2"

# ── 4. pod-side veth ─────────────────────────────────────────────────────────
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

# ── 6. iptables ───────────────────────────────────────────────────────────────
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

# ── 7. persist sysctl ────────────────────────────────────────────────────────
SYSCTL_FILE="/etc/sysctl.d/99-podvm-forward.conf"
echo "Writing ${SYSCTL_FILE}..."
cat > "$SYSCTL_FILE" <<EOF
net.ipv4.ip_forward=1
net.ipv4.conf.${IFACE}.rp_filter=2
net.ipv4.conf.${HOST_VETH}.rp_filter=2
net.ipv4.conf.all.rp_filter=2
EOF

echo "Azure bridge setup completed successfully"
echo "VM IP:         $VM_IP"
echo "Host veth IP:  $HOST_IP (${HOST_VETH})"
echo "Pod veth IP:   $POD_IP (${POD_VETH})"
echo "Pod subnet:    $SUBNET_CIDR"
echo "Exposed ports: ${PORTS[*]}"
