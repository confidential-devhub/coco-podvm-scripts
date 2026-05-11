# Azure Container Hostname Resolution

## Overview

This document describes the dynamic hostname resolution system implemented for Azure confidential containers. The system enables containers to resolve custom hostnames by automatically configuring `/etc/hosts` entries within container namespaces after the kata-agent has fully initialized.

## Architecture

The hostname resolution system consists of three main components:

1. **Dispatcher Service** - Determines the network role and triggers appropriate setup
2. **Server-side Resolution** - Resolves hostnames using existing `/etc/hosts` entries
3. **Client-side Resolution** - Resolves hostnames dynamically using DNS/curl

### Component Flow

```
azure-bridge.service (Dispatcher)
    ↓
    ├─→ [server role] → azure-bridge-server.service → azure-hostname-resolution-server.service
    └─→ [client role] → azure-bridge-client.service → azure-hostname-resolution-client.service
```

## Configuration

### aa.toml Parameters

The system reads configuration from `/run/peerpod/aa.toml`:

```toml
# Network role: "server" or "client"
bridge_role = "server"

# Hostname to resolve
hostname = "example.hostname.com"
```

## Systemd Services

### 1. azure-bridge.service

**Purpose**: Main dispatcher that determines network role and triggers appropriate setup scripts.

**File**: [`scripts/coco/podvm/luks-scratch/etc/systemd/system/azure-bridge.service`](scripts/coco/podvm/luks-scratch/etc/systemd/system/azure-bridge.service)

```ini
[Unit]
Description=Azure Bridge Setup Dispatcher
After=kata-agent.service process-user-data.service
Wants=kata-agent.service process-user-data.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/setup-azure-bridge.sh
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
```

**Script**: [`scripts/coco/podvm/luks-scratch/usr/local/sbin/setup-azure-bridge.sh`](scripts/coco/podvm/luks-scratch/usr/local/sbin/setup-azure-bridge.sh)

- Reads `bridge_role` from aa.toml
- Dispatches to server or client setup scripts
- Automatically triggers hostname resolution after bridge setup

### 2. azure-hostname-resolution-server.service

**Purpose**: Resolves hostnames on server-side containers using existing `/etc/hosts` entries.

**File**: [`scripts/coco/podvm/luks-scratch/etc/systemd/system/azure-hostname-resolution-server.service`](scripts/coco/podvm/luks-scratch/etc/systemd/system/azure-hostname-resolution-server.service)

```ini
[Unit]
Description=Azure Container Hostname Resolution
After=azure-bridge-server.service kata-agent.service
Requires=azure-bridge-server.service
ConditionPathExists=/run/peerpod/aa.toml

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/setup-hostname-resolution-server.sh
Restart=on-failure
RestartSec=10s
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
```

**Script**: [`scripts/coco/podvm/luks-scratch/usr/local/sbin/setup-hostname-resolution-server.sh`](scripts/coco/podvm/luks-scratch/usr/local/sbin/setup-hostname-resolution-server.sh)

**Key Features**:
- Waits for container network interfaces (eth0, eth1) to be ready
- Monitors kata-agent for container process spawning (Java, sleep, pause)
- Reads hostname IP from host's `/etc/hosts`
- Injects hostname entry into container's `/etc/hosts` using `nsenter`

### 3. azure-hostname-resolution-client.service

**Purpose**: Resolves hostnames on client-side containers using dynamic DNS resolution.

**File**: [`scripts/coco/podvm/luks-scratch/etc/systemd/system/azure-hostname-resolution-client.service`](scripts/coco/podvm/luks-scratch/etc/systemd/system/azure-hostname-resolution-client.service)

```ini
[Unit]
Description=Azure Client Container Hostname Resolution
After=azure-bridge-client.service kata-agent.service
Requires=azure-bridge-client.service
ConditionPathExists=/run/peerpod/aa.toml

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/setup-hostname-resolution-client.sh
Restart=on-failure
RestartSec=10s
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
```

**Script**: [`scripts/coco/podvm/luks-scratch/usr/local/sbin/setup-hostname-resolution-client.sh`](scripts/coco/podvm/luks-scratch/usr/local/sbin/setup-hostname-resolution-client.sh)

**Key Features**:
- Waits for container network interfaces (eth0, eth1) to be ready
- Monitors kata-agent for container process spawning
- Resolves hostname dynamically using `curl` with retry logic (20 attempts, 2s delay)
- Extracts IPv4 address from curl verbose output
- Injects hostname entry into container's `/etc/hosts` using `nsenter`

## Implementation Details

### Container Process Detection

Both server and client scripts wait for kata-agent to spawn container processes before attempting hostname resolution. This ensures the container namespace is fully initialized.

**Detection Strategy** (in priority order):
1. Java processes (`grep -i 'java'`)
2. Sleep infinity processes (`grep 'sleep infinity'`)
3. Pause processes (`grep '/pause'`)

**Timeout**: 120 seconds (2 minutes)

### Server-Side Resolution

**Method**: Read from host's `/etc/hosts`

```bash
HOSTNAME_IP=$(grep -E "^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+[[:space:]]+${HOSTNAME}" /etc/hosts | awk '{print $1}')
```

**Advantages**:
- Fast and reliable
- No network dependency
- Uses pre-configured entries from bridge setup

### Client-Side Resolution

**Method**: Dynamic DNS resolution using curl

```bash
HOSTNAME_IP=$(curl -v "http://${HOSTNAME}" 2>&1 | grep -oP 'IPv4: \K[\d.]+' | head -n1)
```

**Retry Logic**:
- Maximum attempts: 20
- Retry delay: 2 seconds
- Total timeout: ~40 seconds

**Advantages**:
- Works without pre-configured entries
- Handles dynamic DNS scenarios
- Robust retry mechanism

### Namespace Entry Injection

Both scripts use `nsenter` to inject hostname entries into the container's `/etc/hosts`:

```bash
nsenter -t ${CONTAINER_PID} -a sh -c "echo '${HOSTNAME_IP} ${HOSTNAME}' >> /etc/hosts"
```

**Flags**:
- `-t`: Target PID
- `-a`: Enter all namespaces (mount, UTS, IPC, net, PID)

## Service Dependencies

```
kata-agent.service
    ↓
azure-bridge.service (dispatcher)
    ↓
    ├─→ azure-bridge-server.service
    │       ↓
    │   azure-hostname-resolution-server.service
    │
    └─→ azure-bridge-client.service
            ↓
        azure-hostname-resolution-client.service
```

## Logging and Debugging

All services log to systemd journal. View logs using:

```bash
# View dispatcher logs
journalctl -u azure-bridge.service

# View server hostname resolution logs
journalctl -u azure-hostname-resolution-server.service

# View client hostname resolution logs
journalctl -u azure-hostname-resolution-client.service

# Follow logs in real-time
journalctl -u azure-hostname-resolution-server.service -f
```

## Troubleshooting

### Hostname Not Resolved

1. **Check aa.toml configuration**:
   ```bash
   cat /run/peerpod/aa.toml
   ```
   Verify `hostname` and `bridge_role` are set correctly.

2. **Check service status**:
   ```bash
   systemctl status azure-hostname-resolution-server.service
   systemctl status azure-hostname-resolution-client.service
   ```

3. **Verify container process detection**:
   ```bash
   ip netns exec podns ps aux
   ```

4. **Check container's /etc/hosts**:
   ```bash
   CONTAINER_PID=$(ip netns exec podns ps aux | grep -i java | head -n1 | awk '{print $2}')
   nsenter -t ${CONTAINER_PID} -a cat /etc/hosts
   ```

### Service Fails to Start

1. **Check dependencies**:
   - Ensure `azure-bridge-server.service` or `azure-bridge-client.service` completed successfully
   - Verify `/run/peerpod/aa.toml` exists

2. **Check network interfaces**:
   ```bash
   ip netns exec podns ip link show
   ```

3. **Manual script execution**:
   ```bash
   /usr/local/sbin/setup-hostname-resolution-server.sh
   # or
   /usr/local/sbin/setup-hostname-resolution-client.sh
   ```

### Client Resolution Timeout

If client-side resolution fails after 20 attempts:

1. **Verify DNS resolution**:
   ```bash
   nslookup ${HOSTNAME}
   dig ${HOSTNAME}
   ```

2. **Test curl manually**:
   ```bash
   curl -v "http://${HOSTNAME}"
   ```

3. **Check network connectivity**:
   ```bash
   ping ${HOSTNAME}
   ```

## Security Considerations

- Scripts run with root privileges (required for `nsenter`)
- Hostname entries are only added if not already present (prevents duplicates)
- Services use `ConditionPathExists` to ensure aa.toml is present
- Retry mechanisms prevent indefinite hanging

## Related Documentation

- [Bridge Setup Documentation](BRIDGE_SETUP.md) - Network bridge configuration
- [DHCP Setup Documentation](scripts/coco/podvm/DHCP-SETUP.md) - DHCP configuration for containers

## Files Modified/Created

### Systemd Service Files
- `scripts/coco/podvm/luks-scratch/etc/systemd/system/azure-bridge.service`
- `scripts/coco/podvm/luks-scratch/etc/systemd/system/azure-hostname-resolution-server.service`
- `scripts/coco/podvm/luks-scratch/etc/systemd/system/azure-hostname-resolution-client.service`

### Setup Scripts
- `scripts/coco/podvm/luks-scratch/usr/local/sbin/setup-azure-bridge.sh`
- `scripts/coco/podvm/luks-scratch/usr/local/sbin/setup-hostname-resolution-server.sh`
- `scripts/coco/podvm/luks-scratch/usr/local/sbin/setup-hostname-resolution-client.sh`

## Future Enhancements

- Support for multiple hostname entries
- IPv6 support
- Configurable retry parameters
- Health check endpoints
- Metrics collection