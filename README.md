# Status Monitor

A lightweight server status monitoring system with two components:

- **worker/** — Cloudflare Worker that receives status pings, stores them in D1 (SQLite), and serves a live dashboard
- **agent/** — Zig binary that collects system metrics and POSTs them to the worker (cross-compiles to Linux and Windows)

## Architecture

```
┌──────────────┐        POST /api/status        ┌─────────────────────┐
│  status-agent│  ──────────────────────────►    │  Cloudflare Worker  │
│  (Linux/Win) │    hostname, cpu, mem, disk     │  + D1 Database      │
└──────────────┘                                 └────────┬────────────┘
                                                          │
                                                   GET /  │
                                                          ▼
                                                 ┌────────────────┐
                                                 │  HTML Dashboard │
                                                 │  (auto-refresh) │
                                                 └────────────────┘
```

## Quick Start

### 1. Deploy the Worker

```bash
cd worker
npm install

# Create the D1 database
npx wrangler d1 create status-monitor-db
# Copy the printed database_id into wrangler.toml

# Apply the schema
npx wrangler d1 execute status-monitor-db --remote --file=schema.sql

# Set your API key
npx wrangler secret put API_KEY

# Deploy
npx wrangler deploy
```

### 2. Build the Agent

Requires [Zig](https://ziglang.org/download/) (tested with 0.15.x).

```bash
# Build for current platform
./build.sh agent

# Build for all platforms
./build.sh agent-all
```

Output binaries land in `agent/zig-out/bin/`:

| File | Target |
|------|--------|
| `status-agent-linux-x86_64` | Linux x86_64 |
| `status-agent-windows-x86_64.exe` | Windows x86_64 |

### 3. Run the Agent

Configure via environment variables:

```bash
export STATUS_ENDPOINT=https://status-monitor.your-subdomain.workers.dev/api/status
export STATUS_API_KEY=your-secret-key
export STATUS_INTERVAL=60  # seconds (default: 60)
./status-agent-linux-x86_64
```

Or copy `config.ini.example` to `config.ini` alongside the binary:

```ini
endpoint = https://status-monitor.your-subdomain.workers.dev/api/status
api_key = your-secret-key
interval = 60
```

## API

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| `POST` | `/api/status` | `X-API-Key` | Submit server metrics |
| `GET` | `/api/status` | — | Get all servers (JSON) |
| `GET` | `/api/status?hostname=X` | — | Get single server (JSON) |
| `GET` | `/api/history?hostname=X` | — | Get metric history (JSON) |
| `DELETE` | `/api/status?hostname=X` | `X-API-Key` | Remove a server and its history |
| `GET` | `/` | — | Live HTML dashboard |

### POST payload

```json
{
  "hostname": "web-01",
  "os": "linux",
  "cpu_usage": 12.5,
  "memory_total": 17179869184,
  "memory_used": 8589934592,
  "disk_total": 1099511627776,
  "disk_used": 549755813888,
  "uptime_seconds": 864000
}
```

## Build Commands

```bash
./build.sh agent          # Native debug build
./build.sh agent-linux    # Linux x86_64 release
./build.sh agent-windows  # Windows x86_64 release
./build.sh agent-all      # All platforms
./build.sh worker         # Install worker deps
./build.sh worker-dev     # Local dev server
./build.sh worker-deploy  # Deploy to Cloudflare
./build.sh all            # Build everything
./build.sh clean          # Remove build artifacts
```

## Metrics Collected

| Metric | Linux | Windows |
|--------|-------|---------|
| Hostname | `/proc/sys/kernel/hostname` | `%COMPUTERNAME%` |
| CPU usage | `/proc/stat` (sampled over 1s) | — |
| Memory | `/proc/meminfo` | `GlobalMemoryStatusEx` |
| Disk | `statfs("/")` | — |
| Uptime | `/proc/uptime` | `GetTickCount64` |
