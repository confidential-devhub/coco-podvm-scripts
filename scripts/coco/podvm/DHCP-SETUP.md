# DHCP Server Setup for Azure Bridge Network

## Overview

The Azure bridge scripts now use DHCP for dynamic IP allocation instead of static IPs. This enables scaling to tens of thousands of VMs without IP exhaustion.

## Network Design

- **Bridge Subnet**: `172.16.0.0/12` (1,048,574 available IPs)
- **Avoids conflicts with**:
  - Flannel CNI: `10.244.0.0/16`
  - OVN-Kubernetes: `10.128.0.0/14`
  - Azure CNI: Uses Azure VNET subnet (typically `10.0.0.0/8` or `192.168.0.0/16`)
  - AWS VPC CNI: Uses VPC CIDR

## DHCP Server Requirements

### Option 1: Single DHCP Server (Small-Medium Scale)

**Recommended for**: Up to 100,000 VMs

```bash
# Install dnsmasq on a dedicated VM in Azure VNET
sudo dnf install -y dnsmasq

# Configure /etc/dnsmasq.conf
interface=eth0
bind-interfaces
dhcp-range=172.16.0.1,172.31.255.254,255.240.0.0,10m
dhcp-option=3  # No default gateway (VMs use Azure VNET routing)
dhcp-leasefile=/var/lib/dnsmasq/dnsmasq.leases
log-dhcp
log-queries

# Enable and start
sudo systemctl enable --now dnsmasq
```

### Option 2: Sharded DHCP Servers (Large Scale)

**Recommended for**: 100,000+ VMs

Deploy multiple DHCP servers, each handling a portion of the IP range:

```bash
# Server 1: 172.16.0.0/16
dhcp-range=172.16.0.1,172.16.255.254,255.255.0.0,10m

# Server 2: 172.17.0.0/16
dhcp-range=172.17.0.1,172.17.255.254,255.255.0.0,10m

# Server 3: 172.18.0.0/16
dhcp-range=172.18.0.1,172.18.255.254,255.255.0.0,10m

# ... up to Server 16: 172.31.0.0/16
```

Use Azure Load Balancer or DHCP relay agents to distribute requests.

### Option 3: ISC DHCP Server (Enterprise)

```bash
# Install ISC DHCP
sudo dnf install -y dhcp-server

# Configure /etc/dhcp/dhcpd.conf
subnet 172.16.0.0 netmask 255.240.0.0 {
    range 172.16.0.1 172.31.255.254;
    default-lease-time 600;
    max-lease-time 7200;
    # No routers option - VMs use Azure VNET routing
}

# Enable and start
sudo systemctl enable --now dhcpd
```

## High Availability Setup

For production, deploy DHCP servers in HA configuration:

```bash
# Primary DHCP server
dhcp-range=172.16.0.1,172.31.255.254,255.240.0.0,10m

# Secondary DHCP server (failover)
dhcp-range=172.16.0.1,172.31.255.254,255.240.0.0,10m
```

Use Azure Availability Sets or Zones to ensure redundancy.

## Network Configuration

### Azure VNET Setup

1. **Create a dedicated subnet** for DHCP server(s):
   ```
   DHCP Subnet: 10.0.255.0/24
   ```

2. **Ensure connectivity** between DHCP subnet and PodVM subnets

3. **Configure NSG rules**:
   - Allow UDP 67 (DHCP server)
   - Allow UDP 68 (DHCP client)

### Firewall Rules on DHCP Server

```bash
# Allow DHCP traffic
sudo firewall-cmd --permanent --add-service=dhcp
sudo firewall-cmd --reload
```

## Monitoring and Troubleshooting

### Check DHCP Leases

**dnsmasq**:
```bash
cat /var/lib/dnsmasq/dnsmasq.leases
```

**ISC DHCP**:
```bash
cat /var/lib/dhcpd/dhcpd.leases
```

### Monitor DHCP Requests

```bash
# dnsmasq
sudo journalctl -u dnsmasq -f

# ISC DHCP
sudo journalctl -u dhcpd -f
```

### Test DHCP from PodVM

```bash
# On PodVM, test DHCP request
sudo dhclient -v eth1
```

### Common Issues

1. **DHCP timeout**: Check network connectivity and NSG rules
2. **IP exhaustion**: Reduce lease time or add more DHCP servers
3. **Lease conflicts**: Ensure DHCP servers don't have overlapping ranges

## Scaling Considerations

| VMs | DHCP Servers | Lease Time | IP Pool Size |
|-----|--------------|------------|--------------|
| 1K-10K | 1 | 10 min | 172.16.0.0/16 (65K IPs) |
| 10K-100K | 2-4 | 5 min | 172.16.0.0/12 (1M IPs) |
| 100K+ | 8-16 (sharded) | 5 min | 172.16.0.0/12 (1M IPs) |

## Lease Reclamation

With short lease times (5-10 minutes), IPs are automatically reclaimed when VMs are deleted. No manual intervention needed.

## Security Considerations

1. **DHCP snooping**: Enable on Azure NSG to prevent rogue DHCP servers
2. **IP reservation**: Reserve specific IPs for critical services
3. **Rate limiting**: Limit DHCP requests per source to prevent DoS

## Migration from Static IPs

The scripts automatically detect and use DHCP. No changes needed to existing deployments - new VMs will use DHCP, old VMs continue with static IPs until recreated.

## References

- dnsmasq documentation: http://www.thekelleys.org.uk/dnsmasq/doc.html
- ISC DHCP documentation: https://www.isc.org/dhcp/
- Azure VNET documentation: https://docs.microsoft.com/azure/virtual-network/