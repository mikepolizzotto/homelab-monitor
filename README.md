# homelab-monitor

Modular homelab monitoring system that sends daily briefings and backup verification alerts via [Pushover](https://pushover.net) push notifications. Designed for macOS but adaptable to Linux.

Built with love by humans and robots.

## What It Does

**Morning Briefing** — Daily push notification at 7:30 AM with:
- Weather forecast
- Device availability (SSH + ping checks)
- Network status (client count, unknown device detection, WAN, firewall rules)
- Disk health (Synology SMART/temps, ZFS pool status)
- Backup freshness (S3-compatible storage)
- Home sensors (Homebridge: climate, air quality, garage door, security system)
- Irrigation (Rachio: rain skips, active watering, forecast)

**Backup Verification** — Weekly integrity check of S3-compatible backup storage:
- Object count and size delta tracking
- Anomaly detection (object loss >5%, zero growth, size decrease, staleness)
- Quiet notifications when clean, high priority on anomalies

## Architecture

Each monitoring area is a standalone module. The main scripts source whichever modules you want. Pick what's relevant to your setup, ignore the rest.

```
homelab-monitor/
├── scripts/
│   ├── morning_briefing.sh          # Main daily briefing
│   ├── backup_verify.sh             # Weekly backup integrity check
│   └── modules/
│       ├── pushover.sh              # Notification delivery
│       ├── infra.sh                 # Device availability
│       ├── disks.sh                 # Synology + ZFS disk health
│       ├── backups.sh               # S3 backup freshness
│       ├── network.sh               # Network + security checks
│       ├── homebridge.sh            # Smart home via Homebridge API
│       ├── weather.sh               # Weather (Open-Meteo, free)
│       └── rachio.sh                # Irrigation (Rachio API)
├── config/
│   ├── pushover.env.example         # Pushover credentials template
│   ├── rachio.env.example           # Rachio API key template
│   ├── wasabi.env.example           # S3 storage config template
│   └── homebridge.env.example       # Homebridge API config template
├── launchd/
│   ├── com.homelab.morning-briefing.plist
│   └── com.homelab.backup-verify.plist
└── docs/
    └── macos-ssh-postquantum-kex.md # Fix for macOS 26.x SSH + older devices
```

## Quick Start

### 1. Clone and configure

```bash
git clone https://github.com/YOUR_USERNAME/homelab-monitor.git ~/homelab
mkdir -p ~/.config/homelab

# Copy and fill in your credentials
cp ~/homelab/config/pushover.env.example ~/.config/homelab/pushover.env
# Edit with your Pushover user key and API token
```

### 2. Configure modules

Edit the device arrays and SSH aliases in each module you want to use. Every module has a `CONFIGURATION` section at the top.

At minimum, set up `~/.ssh/config` with aliases for your devices:

```
Host nas1
    HostName 192.168.1.100
    User admin
    IdentityFile ~/.ssh/id_ed25519

Host router
    HostName 192.168.1.1
    User root
    IdentityFile ~/.ssh/id_ed25519
```

### 3. Test manually

```bash
# Run the full briefing
bash ~/homelab/scripts/morning_briefing.sh

# Run just one module
source ~/homelab/scripts/modules/weather.sh && check_weather
source ~/homelab/scripts/modules/infra.sh && check_infra
```

### 4. Schedule

**macOS (launchd):**

```bash
# Edit the plist to set your home directory path
cp ~/homelab/launchd/com.homelab.morning-briefing.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.homelab.morning-briefing.plist
```

**Linux (cron):**

```bash
# Daily at 7:30 AM
30 7 * * * /bin/bash -l /home/you/homelab/scripts/morning_briefing.sh

# Weekly backup verification (Sundays at 9 AM)
0 9 * * 0 /bin/bash -l /home/you/homelab/scripts/backup_verify.sh
```

## Modules

### Core (always useful)
| Module | What it checks | Requirements |
|--------|---------------|--------------|
| `pushover.sh` | Notification delivery | [Pushover](https://pushover.net) account |
| `infra.sh` | Device availability via SSH/ping | SSH keys deployed |
| `weather.sh` | Daily forecast | None (free API, no key needed) |

### Storage
| Module | What it checks | Requirements |
|--------|---------------|--------------|
| `disks.sh` | Synology SMART + ZFS pool health | SSH access to NAS devices |
| `backups.sh` | S3 backup freshness | AWS CLI with named profile |
| `backup_verify.sh` | Weekly backup integrity + anomaly detection | AWS CLI with named profile |

### Network
| Module | What it checks | Requirements |
|--------|---------------|--------------|
| `network.sh` | Clients, unknown devices, WAN, firewall, SSH failures | SSH access to router |

### Smart Home
| Module | What it checks | Requirements |
|--------|---------------|--------------|
| `homebridge.sh` | Thermostat, air quality, garage door, security | [Homebridge](https://homebridge.io) with API |
| `rachio.sh` | Rain skips, watering status, forecast | [Rachio](https://rachio.com) API key |

## Prerequisites

- **macOS** (uses `date -j` for date parsing; Linux would need `date -d` instead)
- **bash** 4.0+ (macOS ships 3.2, install via `brew install bash`)
- **SSH keys** deployed to all monitored devices
- **AWS CLI** (for backup modules): `brew install awscli`
- **python3** (for JSON parsing in some modules)
- **curl** (comes with macOS)

## Docs

- **[macOS SSH Post-Quantum Kex Fix](docs/macos-ssh-postquantum-kex.md)** — If SSH to your network devices breaks after upgrading to macOS Tahoe (26.x), this is why and how to fix it.

## Tips

- **Start small.** Get `infra.sh` and `weather.sh` working first, then add modules.
- **Test modules individually** before wiring them into the briefing.
- **Conditional modules** like `rachio.sh` only output when something noteworthy happens — no news is good news.
- **Known devices baseline**: run `source modules/network.sh && generate_baseline` to snapshot your current network, then new devices trigger alerts.
- **Backup baseline**: the first run of `backup_verify.sh` creates the baseline; deltas start on the second run.

## License

MIT — do whatever you want with it.
