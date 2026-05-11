# Bridge Setup Guide for Direct VM-to-Container Communication

## Azure Private DNS Integration

The bridge setup scripts now support automatic hostname registration in Azure Private DNS zones. This enables hostname-based service discovery across your peer pod infrastructure.

### Prerequisites

1. **Azure Private DNS Zone**: Create a private DNS zone (e.g., `spark.local`)
2. **Service Principal**: Create a service principal with appropriate permissions
3. **Required Permissions**: Service principal needs **Private DNS Zone Contributor** role on the DNS zone

### Configuration

Add the following to your `aa.toml` configuration file:

```toml
# Hostname for this VM (will be registered as hostname.spark.local)
hostname = "spark-master"

# Azure credentials for DNS registration
azure_client_id = "your-client-id"
azure_client_secret = "your-client-secret"
azure_tenant_id = "your-tenant-id"
azure_subscription_id = "your-subscription-id"
```

### How It Works

When the server bridge setup script runs:

1. **Hostname Configuration**: Sets the system hostname and configures DHCP to send it
2. **Azure Authentication**: Logs in using the service principal credentials
3. **DNS Registration**: Creates/updates an A record mapping `hostname.spark.local` to the VM's IP
4. **Verification**: Confirms the DNS record was created successfully

### DNS Record Format

The script creates A records in the format:
```
hostname.spark.local → VM_IP_ADDRESS
```

Example:
```
spark-master.spark.local  → 10.0.1.10
spark-worker-1.spark.local → 10.0.1.11
spark-worker-2.spark.local → 10.0.1.12
```

### Service Principal Setup

Create a service principal with DNS permissions:

```bash
# Create service principal
az ad sp create-for-rbac --name "peer-pods-dns-updater" \
  --role "Private DNS Zone Contributor" \
  --scopes /subscriptions/{subscription-id}/resourceGroups/{resource-group}/providers/Microsoft.Network/privateDnsZones/{dns-zone-name}

# Output will include:
# - appId (use as azure_client_id)
# - password (use as azure_client_secret)
# - tenant (use as azure_tenant_id)
```

### Troubleshooting DNS Registration

Check the script logs for DNS registration status:
```bash
# View systemd service logs
sudo journalctl -u azure-bridge-server.service -f

# Common issues:
# - "Azure CLI not found": Install Azure CLI
# - "Authentication failed": Check service principal credentials
# - "Failed to create DNS A record": Verify service principal has correct permissions
# - "Private DNS zone not found": Verify zone name and resource group
```

### Installing Azure CLI

If Azure CLI is not installed on the VM image:

```bash
# Install Azure CLI
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash

# Verify installation
az --version
```

### Benefits

- **Automatic Registration**: VMs automatically register their hostnames on boot
- **Service Discovery**: Applications can use hostnames instead of IPs
- **Dynamic Updates**: DNS records update if VM IPs change
- **Centralized Management**: All hostname mappings in one Azure Private DNS zone
- **No Manual Configuration**: Eliminates need to manually maintain DNS records

This guide documents the complete setup for enabling direct communication between peer pod containers bypassing the Kubernetes VXLAN overlay network.

## Architecture Overview

```
Client Container (192.168.0.101)
    ↓ eth1
Client Bridge (192.168.0.51)
    ↓ eth0
Client VM (192.168.0.10)
    ↓ Azure VNET
Server VM (192.168.0.11)
    ↓ iptables DNAT
Server Bridge (192.168.0.50)
    ↓ eth1
Server Container (10.129.2.25)
```

## Server VM Setup

### 0. Configure Hostname via DHCP (Optional but Recommended)

This step configures the VM to send its hostname via DHCP and sets the system hostname. This helps with identification and can enable hostname-based communication if DNS is configured.

```bash
# Find your eth0 connection name
nmcli connection show

# Configure to send hostname via DHCP (connection name is typically "Wired connection 1")
sudo nmcli connection modify "Wired connection 1" \
    ipv4.dhcp-send-hostname yes \
    ipv4.dhcp-hostname "server-peerpod"

# Apply changes
sudo nmcli connection down "Wired connection 1"
sudo nmcli connection up "Wired connection 1"

# Verify DHCP hostname configuration
nmcli connection show "Wired connection 1" | grep dhcp-hostname

# Set the system hostname permanently
sudo hostnamectl set-hostname server-peerpod

# Verify hostname
hostnamectl
hostname
hostname -f
```

**Note**: If your DHCP server supports dynamic DNS updates, this hostname will be registered automatically. This is particularly useful when using an external DHCP server in the same VNET.

### 1. Create Bridge Network

```bash
# Create veth pair in podns namespace
sudo ip netns exec podns ip link add eth1 type veth peer name veth-azure
sudo ip netns exec podns ip addr add 192.168.0.100/24 dev eth1
sudo ip netns exec podns ip link set eth1 up
sudo ip netns exec podns ip link set veth-azure netns 1

# Create bridge in host namespace
sudo ip link add br-azure type bridge
sudo ip link set veth-azure master br-azure
sudo ip link set veth-azure up
sudo ip link set br-azure up
sudo ip addr add 192.168.0.50/24 dev br-azure
```

### 2. Configure Routing

```bash
# Add route in container namespace
sudo ip netns exec podns ip route add 192.168.0.0/24 dev eth1

# Add specific host route
sudo ip route add 192.168.0.100/32 dev br-azure

# Delete conflicting subnet route
sudo ip route del 192.168.0.0/24 dev br-azure

# Add route to Client container
sudo ip route add 192.168.0.101/32 via 192.168.0.10 dev eth0
```

### 3. Enable Proxy ARP and Forwarding

```bash
sudo sysctl -w net.ipv4.conf.all.proxy_arp=1
sudo sysctl -w net.ipv4.conf.br-azure.proxy_arp=1
sudo sysctl -w net.ipv4.ip_forward=1
```

### 4. Configure iptables DNAT Rules

```bash
# First DNAT: VM IP → Bridge IP
sudo iptables -t nat -A PREROUTING -d 192.168.0.11 -p tcp --dport 8080 -j DNAT --to-destination 192.168.0.100:8080
sudo iptables -t nat -A OUTPUT -d 192.168.0.11 -p tcp --dport 8080 -j DNAT --to-destination 192.168.0.100:8080

# Second DNAT: Bridge IP → Container IP
sudo iptables -t nat -A PREROUTING -d 192.168.0.100 -p tcp --dport 8080 -j DNAT --to-destination 10.129.2.25:8080
sudo iptables -t nat -A OUTPUT -d 192.168.0.100 -p tcp --dport 8080 -j DNAT --to-destination 10.129.2.25:8080

# MASQUERADE for return traffic
sudo iptables -t nat -A POSTROUTING -d 10.129.2.25 -p tcp --dport 8080 -j MASQUERADE
```

## Client VM Setup

### 0. Configure Hostname via DHCP (Optional but Recommended)

This step configures the VM to send its hostname via DHCP and sets the system hostname.

```bash
# Find your eth0 connection name
nmcli connection show

# Configure to send hostname via DHCP (connection name is typically "Wired connection 1")
sudo nmcli connection modify "Wired connection 1" \
    ipv4.dhcp-send-hostname yes \
    ipv4.dhcp-hostname "client-peerpod"

# Apply changes
sudo nmcli connection down "Wired connection 1"
sudo nmcli connection up "Wired connection 1"

# Verify DHCP hostname configuration
nmcli connection show "Wired connection 1" | grep dhcp-hostname

# Set the system hostname permanently
sudo hostnamectl set-hostname client-peerpod

# Verify hostname
hostnamectl
hostname
hostname -f
```

**Note**: This allows the client VM to be identified by hostname rather than just IP address, which is useful for logging and troubleshooting.

### 1. Create Bridge Network

```bash
# Create veth pair with different IP (192.168.0.101)
sudo ip netns exec podns ip link add eth1 type veth peer name veth-azure
sudo ip netns exec podns ip addr add 192.168.0.101/24 dev eth1
sudo ip netns exec podns ip link set eth1 up
sudo ip netns exec podns ip link set veth-azure netns 1

# Create bridge
sudo ip link add br-azure type bridge
sudo ip link set veth-azure master br-azure
sudo ip link set veth-azure up
sudo ip link set br-azure up
sudo ip addr add 192.168.0.51/24 dev br-azure
```

### 2. Configure Routing

```bash
# Add route in container namespace
sudo ip netns exec podns ip route add 192.168.0.0/24 dev eth1

# Add specific host route
sudo ip route add 192.168.0.101/32 dev br-azure

# Delete conflicting subnet route
sudo ip route del 192.168.0.0/24 dev br-azure
```

### 3. Enable Proxy ARP and Forwarding

```bash
sudo sysctl -w net.ipv4.conf.all.proxy_arp=1
sudo sysctl -w net.ipv4.conf.br-azure.proxy_arp=1
sudo sysctl -w net.ipv4.ip_forward=1
```

### 4. Configure iptables for Forwarding

```bash
# Allow forwarding between bridge and eth0
sudo iptables -I FORWARD -i br-azure -o eth0 -j ACCEPT
sudo iptables -I FORWARD -i eth0 -o br-azure -j ACCEPT

# MASQUERADE outgoing traffic from container
sudo iptables -t nat -A POSTROUTING -s 192.168.0.101/32 -o eth0 -j MASQUERADE
```

## Test Cases

### Test 1: Server VM ↔ Server Container

```bash
# On Server VM

# VM → Container
curl http://192.168.0.11:8080
# Expected: "Hello from VM IP"

# Container → VM (start test server first)
python3 -m http.server 9090 &
sudo ip netns exec podns curl http://192.168.0.11:9090
# Expected: Directory listing
kill %1
```

### Test 2: Client VM ↔ Client Container

```bash
# On Client VM

# VM → Container bridge
ping -c 2 192.168.0.101
# Expected: 0% packet loss

# Container → VM bridge
sudo ip netns exec podns ping -c 2 192.168.0.51
# Expected: 0% packet loss
```

### Test 3: Server VM ↔ Client VM

```bash
# From Server VM
curl http://192.168.0.10:9090
# (Requires test server running on Client VM)

# From Client VM
curl http://192.168.0.11:8080
# Expected: "Hello from VM IP"
```

### Test 4: Client Container → Server Container (Main Goal)

```bash
# On Client VM

# Ping test
sudo ip netns exec podns ping -c 2 192.168.0.11
# Expected: 0% packet loss

# HTTP test
sudo ip netns exec podns curl http://192.168.0.11:8080
# Expected: "Hello from VM IP"
```

## Verification Commands

### Check Bridge Status

```bash
# On both VMs
ip link show | grep -E "br-azure|veth-azure"
bridge link show
```

### Check IP Addresses

```bash
# On both VMs
ip addr show br-azure
sudo ip netns exec podns ip addr show eth1
```

### Check Routes

```bash
# On both VMs
ip route show | grep 192.168.0
sudo ip netns exec podns ip route show | grep 192.168.0
```

### Check iptables Rules

```bash
# On Server VM
sudo iptables -t nat -L PREROUTING -n -v | grep 8080
sudo iptables -t nat -L OUTPUT -n -v | grep 8080
sudo iptables -t nat -L POSTROUTING -n -v | grep 8080

# On Client VM
sudo iptables -L FORWARD -n -v
sudo iptables -t nat -L POSTROUTING -n -v
```

### Check Proxy ARP

```bash
# On both VMs
sysctl net.ipv4.conf.all.proxy_arp
sysctl net.ipv4.conf.br-azure.proxy_arp
sysctl net.ipv4.ip_forward
```

## Troubleshooting

### Issue: Ping works but curl fails
- Check iptables DNAT rules exist
- Verify nginx is running: `sudo ip netns exec podns ss -tlnp | grep 8080`
- Check iptables counters: `sudo iptables -t nat -L -n -v | grep 8080`

### Issue: Connection hangs
- Flush conntrack table: `sudo conntrack -F`
- Check if conntrack table is full: `dmesg | grep conntrack`

### Issue: ARP resolution fails
- Enable proxy ARP on all interfaces
- Check ARP entries: `sudo ip netns exec podns ip neigh show`
- Manually add ARP if needed: `sudo ip netns exec podns ip neigh add <IP> lladdr <MAC> dev eth1`

### Issue: Route conflicts
- Ensure no `192.168.0.0/24 dev br-azure` route exists
- Only specific host routes should use br-azure
- Azure VNET traffic should use eth0

## Key Points

1. **Different Bridge IPs**: Server uses 192.168.0.100, Client uses 192.168.0.101
2. **MASQUERADE Required**: Client needs MASQUERADE for outgoing traffic
3. **Bidirectional Routes**: Server needs route to Client's bridge IP via Client VM
4. **Proxy ARP**: Essential for ARP resolution across namespaces
5. **DNAT Chain**: Server uses double DNAT (VM IP → Bridge IP → Container IP)
6. **No Subnet Routes**: Delete auto-created `192.168.0.0/24 dev br-azure` routes

## Success Criteria

✅ Client container can curl Server container on port 8080  
✅ Traffic bypasses Kubernetes VXLAN overlay  
✅ Direct VM-to-VM container communication established  
✅ Port 8080 accessible via Azure VM private IP