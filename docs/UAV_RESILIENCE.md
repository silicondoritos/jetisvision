---
title: Platform Resilience
layout: default
description: "Phase 7 hardening: systemd watchdog, persistent journald, kdump, security hardening, chrony time sync, brownout guard, PCIe AER."
nav_order: 20
---

# Platform Hardening (Phase 7)

**Phase 7 is optional.** The baseline (Phases 1–4) is complete without it. Install Phase 7 for production-grade operational hardening.

Phase 7 components split into two groups:

- **General hardening** (§1–8 below) — useful on any embedded Linux deployment, not platform-specific. Watchdog, journald, chrony, SSH/UFW hardening, NVMe SMART.
- **Vision-stack-specific** (§9 below) — requires the Metis NPU. Brownout guard, black-box recorder, PCIe AER monitor.

Black-box recorder: [BLACKBOX]({{ '/BLACKBOX' | relative_url }}).

## What gets installed

`scripts/install_uav_phase7.sh` is the single entry point. It calls
seven sub-installers, each pre/post-verified:

1. **`install_uav_resilience.sh`** — core hardening + power/storage
   config files (this doc + `FINE_TUNING.md`)
2. **`install_blackbox.sh`** — black-box recorder service → `BLACKBOX.md`
3. **brownout guard** (inline) — `axelera_brownout_guard.sh` + service
4. **PCIe AER monitor** (inline) — `jetson_pcie_aer_monitor.sh` + service;
   forwards correctable + non-fatal + fatal AER counter increases into
   the black-box event stream → `FINE_TUNING.md` §5
5. **`install_data_partition.sh`** — durable btrfs data partition →
   `DATA_PARTITION.md`

Marker file: `/etc/jetson-av-resilience-installed`.

## General hardening (§1–8) — useful on any deployment

Configuration files written at install time (single source of truth for
cross-component coordination — see `FINE_TUNING.md`):

- `/etc/jetson-av/power.conf` — NVPMODEL, GPU/EMC caps, fan, Metis power cap
- `/etc/jetson-av/storage.conf` — NVMe write cache policy
- `/etc/jetson-av/expectations.conf` — driver-loaded loud-fail set
- `/etc/jetson-av/blackbox.conf` — recorder cadence + topics

## Components

### 1. Hardware + systemd watchdog

```
/etc/systemd/system.conf.d/10-watchdog.conf
  RuntimeWatchdogSec=30s
  RebootWatchdogSec=2min
```

The Tegra hardware watchdog at `/dev/watchdog` is petted by systemd-pid1
every 30 s. If pid1 dies (e.g., kernel hang, OOM cascade), the hardware
forces a reboot at the 2-minute mark — the vehicle won't be stuck in a
zombie state.

Per-service WatchdogSec in the mission-critical units:

- `jetson-blackbox.service`: `WatchdogSec=120` — flush within 2 min or get
  restarted.

To extend to your own services, add `WatchdogSec=` and call
`sd_notify(0, "WATCHDOG=1")` periodically.

### 2. Persistent journald

```
/var/log/journal/        ← created (was missing → volatile /run/log/journal)
/etc/systemd/journald.conf.d/10-av.conf
  Storage=persistent
  SystemMaxUse=2G
  SystemKeepFree=4G
  SystemMaxFileSize=128M
```

After this, `journalctl -b -1` shows the previous boot's logs. Without
it, every reboot wipes the journal.

### 3. /tmp on tmpfs

Stock Ubuntu uses disk `/tmp`. On an autonomous platform, that means months of writes
into the same NVMe sectors → wear. `tmp.mount` is enabled to mount
`/tmp` as tmpfs (size=2G, nosuid/nodev/strictatime).

### 4. logrotate AV rules

`/etc/logrotate.d/jetson-av` rotates syslog/auth/kern aggressively (7
days), and gives `/var/log/jetson-av/*.log` longer retention (30 days)
since those are the AV-specific logs.

### 5. chrony NTP (and optional PTP)

Systemd-timesyncd is the stock time source — it's coarse. Chrony with
`makestep 1.0 3` makes a sharp step within the first 3 polls if the
clock is off, then disciplines smoothly. Critical for log correlation
across SLAM / inference / black-box.

If you have a GPS PPS source, hook it via `gpsd` and add to
`chrony.conf`:

```
refclock SHM 0 refid GPS precision 1e-1 noselect
refclock PPS /dev/pps0 refid PPS lock GPS prefer
```

### 6. SSH hardening

```
/etc/ssh/sshd_config.d/10-av-hardening.conf
  PasswordAuthentication no
  PermitRootLogin no
  ClientAliveInterval 60
  ClientAliveCountMax 2
```

Push your operator public keys into `/home/j/.ssh/authorized_keys` at
bake time or via your fleet provisioning workflow. With password auth
off, an unprovisioned device cannot be SSHed to even if it's on the
LAN — no cleartext password attack surface.

### 7. UFW firewall

```
ufw default deny incoming
ufw default allow outgoing
ufw allow ssh
ufw allow 7400:7500/udp     # FastDDS multicast (ROS 2)
```

Add your own rules per deployment (e.g., GCS port, RTSP, telemetry
relay) before flying. UFW's policy persists across reboot.

### 8. NVMe SMART

`smartmontools` enabled and started so SSD wear, temperature, and
remaining-life can be polled. Read with:

```bash
sudo smartctl -a /dev/nvme0n1
sudo nvme smart-log /dev/nvme0
```

Add a periodic check to your monitoring stack — Jetson Orin's NVMe is
the single most likely physical-failure point in the system.

## Vision-stack-specific hardening (§9) — requires Metis NPU

The following components depend on Layer 2 (Metis inference). Do not install unless Phase 5 and the Metis driver are active.

### 9. Brownout guard (Axelera Metis)

The Metis NPU spikes to ~20 W under full INT8 load. On battery + DC-DC,
those spikes can sag the rail enough to brownout the PCIe link, at
which point the device disappears from `lspci` and inference dies.

`axelera_brownout_guard.sh` (run as `jetson-brownout-guard.service`):

1. At start: applies `axdevice --set-power-limit 18` (configurable in
   `/etc/jetson-av/brownout.conf`).
2. Every 5 s: polls `lspci -d 1f9d:` for the Metis vendor ID
   (Axelera AI vendor 1f9d, device 1100).
3. On disappearance: emits a black-box event (`metis_lost`), runs
   `/sys/bus/pci/rescan` to try to recover the link.

Tune `AXELERA_POWER_LIMIT_W` per your power architecture. 18 W is
conservative; 20 W is the device max but assumes a PSU that can absorb
the spike.

### 10. Kernel CONFIG additions

Already in the AV defconfig (`scripts/01_extract_and_patch.sh`):

```
CONFIG_KEXEC=y                   ← kdump capability
CONFIG_KEXEC_FILE=y
CONFIG_CRASH_DUMP=y
CONFIG_PROC_VMCORE=y
CONFIG_SECURITY=y
CONFIG_SECURITY_YAMA=y
CONFIG_SECURITY_LOCKDOWN_LSM=y
CONFIG_LSM="yama,lockdown,integrity"
CONFIG_TCG_TPM=y
CONFIG_TCG_TIS=y
CONFIG_HW_RANDOM_TPM=y
```

These enable kdump (full crash dump capture with `kdump-tools`), Yama
LSM (`ptrace_scope=1` enforced), Lockdown LSM (block live kernel
patching once active), and the TPM TIS interface for hardware RNG +
attestation if your carrier has a TPM.

## Verification on a flashed device

```bash
# All Phase 7 services running?
systemctl --no-pager --type=service \
    list-unit-files 'jetson-*.service' tmp.mount

# Watchdog active?
systemctl status systemd                # look for "Runtime watchdog: 30s"
ls /dev/watchdog*

# Persistent journal?
ls /var/log/journal/                    # populated; not empty
journalctl --disk-usage

# Time sync?
chronyc sources                         # shows ^* primary
chronyc tracking                        # offset typically <100 ms

# Firewall?
sudo ufw status verbose

# Marker?
cat /etc/jetson-av-resilience-installed
```

The post-flash validator (`make verify`) does most of these
automatically. Run it; if it returns 0, Phase 7 is correctly installed.

## Disabling components

Each piece is independently controllable via systemd:

```bash
# Disable the brownout guard (e.g., on a wall-powered dev unit)
sudo systemctl disable --now jetson-brownout-guard.service

# Lower the journald cap (e.g., tiny SSD)
sudo sed -i 's/SystemMaxUse=2G/SystemMaxUse=512M/' \
    /etc/systemd/journald.conf.d/10-av.conf
sudo systemctl restart systemd-journald
```

To skip Phase 7 entirely at first-boot (e.g., debugging):

```bash
SKIP_PHASE7=1 sudo /home/j/jetson_first_boot.sh
```

(Currently `jetson_first_boot.sh` does not honor `SKIP_PHASE7` — add it
yourself if you need this; trivial change.)

## Verify framework

Every Phase 7 install step runs through `step::run` (see
`docs/VERIFICATION.md`). The full installer's manifest:

```
[2026-05-06T18:32:01]  Install platform resilience       PASS  62s
[2026-05-06T18:33:03]  Install black-box recorder   PASS  18s
[2026-05-06T18:33:21]  Install brownout guard       PASS  8s
```

Per-step logs at `logs/`. Bundle for support: `make logs`.
