---
title: Telemetry Failover
layout: default
description: "Doodle Labs primary + RockBLOCK 9704 Iridium IMT secondary failover wired through mavlink-router with automatic switchover."
nav_order: 23
---

# Telemetry Failover — Doodle Labs Primary + Iridium IMT Failsafe

Doodle Labs Helix: high-bandwidth primary. RockBLOCK 9704 Iridium IMT: low-bandwidth failsafe — works regardless of GCS mesh range.
> Pure userspace stack — only kernel knob is `CONFIG_USB_SERIAL_FTDI_SIO=m` (in the AV defconfig) so the RockBLOCK 9704 enumerates as `/dev/ttyUSB0`.

## Architecture

```
                    ┌────────────┐
   FCU (Pixhawk 6X) │ TELEM UART │  /dev/ttyTHS1  @ 921600
                    └─────┬──────┘
                          │
                          ▼
              ┌────────────────────────┐
              │    mavlink-router      │  /etc/jetson-av/mavlink-router.conf
              │  (fan-out daemon)      │
              └────┬───────┬────────┬──┘
                   │       │        │
        ┌──────────┘       │        └─────────────┐
        ▼                  ▼                      ▼
   UDP :14550        TCP :5760             UDP :14540 (local)
   ┌───────────┐    ┌──────────┐          ┌───────────┐
   │ Doodle    │    │ Iridium  │          │  MAVROS   │
   │ Labs      │    │ SBD      │          │  (ROS 2)  │
   │ Helix     │    │ relay    │          └───────────┘
   │ → GCS     │    │ → modem  │
   └───────────┘    └──────────┘
                           │
                           ▼
                    /dev/ttyUSB0
                    RockBLOCK 9704
                    (Iridium IMT)
                           │
                           ▼
                  Iridium constellation
                           │
                           ▼
                  GCS via Rock7 webhook
```

mavlink-router takes one input (the FCU UART) and fans out to multiple
endpoints. Each endpoint is independent — if Doodle Labs goes down, the
Iridium relay keeps working from the same TCP server.

## Components installed

| Component | Path | What it does |
|---|---|---|
| `mavlink-router` | `/usr/bin/mavlink-routerd` | Fan-out daemon |
| Router config template | `/etc/jetson-av/mavlink-router.conf` | Endpoints (FCU UART + GCS UDP + local TCP/UDP) |
| Main config | `/etc/jetson-av/telemetry-failover.conf` | Tunables |
| Iridium relay | `/usr/local/bin/jetson-av-iridium-relay` | Pulls from TCP :5760, sends IMT packet via JSPR JSON to `/dev/ttyUSB0` |
| Link monitor | `/usr/local/bin/jetson-av-link-monitor` | Watches GCS heartbeat, flips `/run/jetson-av-link-state` |
| Router service | `jetson-av-mavlink-router.service` | systemd unit; restart=always |
| Iridium service | `jetson-av-iridium-relay.service` | systemd unit; depends on router + monitor |
| Link monitor service | `jetson-av-link-monitor.service` | systemd unit |

## Configuration (the only file you typically edit)

`/etc/jetson-av/telemetry-failover.conf`:

```sh
FCU_TTY=/dev/ttyTHS1          # Pixhawk TELEM2 — verify with: dmesg | grep ttyTHS
FCU_BAUD=921600
PRIMARY_GCS_HOST=192.168.10.1 # GCS reachable via Doodle Labs Helix
PRIMARY_GCS_PORT=14550
IRIDIUM_TTY=/dev/ttyUSB0      # RockBLOCK 9704 (FTDI USB-serial)
IRIDIUM_BAUD=230400
SBD_INTERVAL_NORMAL=60        # cadence when primary is healthy
SBD_INTERVAL_DEGRADED=15      # cadence when primary is down
PRIMARY_TIMEOUT=10            # seconds without GCS heartbeat → degraded
```

After edits:

```bash
sudo systemctl restart jetson-av-mavlink-router.service \
                       jetson-av-link-monitor.service \
                       jetson-av-iridium-relay.service
```

## Cadence and packet contents

The Iridium relay sends a binary packet every `SBD_INTERVAL_NORMAL`
seconds (default 60s) when primary is OK, every `SBD_INTERVAL_DEGRADED`
seconds (default 15s) when degraded.

Packet payload (~36 bytes binary + 2 byte CRC):

| Field | Type | Source MAVLink message |
|---|---|---|
| timestamp_unix | uint32 | `time.time()` |
| latitude_e7 | int32 | `GLOBAL_POSITION_INT.lat` |
| longitude_e7 | int32 | `GLOBAL_POSITION_INT.lon` |
| altitude_mm | int32 | `GLOBAL_POSITION_INT.alt` |
| roll_rad | float32 | `ATTITUDE.roll` |
| pitch_rad | float32 | `ATTITUDE.pitch` |
| yaw_rad | float32 | `ATTITUDE.yaw` |
| voltage_v | float32 | `SYS_STATUS.voltage_battery / 1000` |
| current_a | float32 | `SYS_STATUS.current_battery / 100` |
| throttle | uint16 | `RC_CHANNELS.chan3_raw` |

Iridium IMT pricing: each mobile-originated packet costs ~$0.95–$1.50 depending on plan. At 60s cadence over a 30 min flight that's ~$30/flight at degraded rates. Tune `SBD_INTERVAL_NORMAL` to your budget.

To extend the packet (add airspeed, GPS satellites, mode), edit
`/usr/local/bin/jetson-av-iridium-relay` — `struct.pack(...)` is the only
place you change.

## Verify on the device

```bash
# Services healthy?
systemctl is-active jetson-av-mavlink-router.service \
                    jetson-av-link-monitor.service \
                    jetson-av-iridium-relay.service

# Router stats
journalctl -u jetson-av-mavlink-router.service -f

# Current link state (ok | degraded)
cat /run/jetson-av-link-state

# See SBD packets being sent
journalctl -u jetson-av-iridium-relay.service -f
# → "[iridium-relay] queued IMT packet (36b)"

# Talk to the FCU directly via the local TCP server
nc 127.0.0.1 5760 | xxd | head     # raw mavlink stream
```

## Black-box integration

Both daemons emit events into `/var/run/jetson-av-events`, which the
black-box recorder drains into the per-flight `events.jsonl`:

```jsonl
{"src":"link_monitor","e":"primary_lost","v":"15"}
{"src":"iridium_relay","e":"sbd_sent","v":36}
{"src":"link_monitor","e":"primary_recovered","v":"1"}
```

This means a post-flight forensic review can correlate exactly when the
link dropped, when the failover started, and what telemetry packets made
it out via Iridium.

## Failure modes

### "no /dev/ttyUSB0" at install time

The 9704 uses FTDI USB-serial — needs `CONFIG_USB_SERIAL_FTDI_SIO=m`. Confirm:

```bash
zcat /proc/config.gz | grep CONFIG_USB_SERIAL_FTDI_SIO
# expect: CONFIG_USB_SERIAL_FTDI_SIO=m
modprobe ftdi_sio 2>&1
lsusb | grep FTDI
```

If not present, rebuild the kernel after adding it to the defconfig in `01_extract_and_patch.sh` (already in the AV defconfig as of Phase-7-+).

### Iridium relay can't connect to mavlink-router

It retries every 5s. Confirm router is up: `systemctl status
jetson-av-mavlink-router.service`. Check `/var/log/jetson-av/mavlink-router.log`
for FCU UART errors.

### Iridium link is up but no packets received GCS-side

Verify the IMT account is active and the modem has antenna sky view. Check send errors in `journalctl -u jetson-av-iridium-relay.service`.

### Cost runs hot

`SBD_INTERVAL_NORMAL=60` is conservative; can be `300` (5 min) for
slow-changing missions. `SBD_INTERVAL_DEGRADED=15` may also be too
aggressive for budget; `30s` halves the cost during degraded periods.
Edit `/etc/jetson-av/telemetry-failover.conf`.

### Doodle Labs link goes flaky but doesn't fully drop

`PRIMARY_TIMEOUT=10` may flap between ok and degraded. Increase to 30s
to dampen the state change.

## What's NOT here yet

- **Cellular failsafe** (M.2 LTE/5G modem). The kernel has
  `CONFIG_USB_USBNET=m` and `CONFIG_USB_NET_RNDIS_HOST=m` for this; the
  systemd networkd config is not yet automated. Manual: drop
  `/etc/systemd/network/30-cellular.network` per modem vendor.
- **MAVLink-over-MQTT** for IoT-style telemetry tunneling. Stretch goal.
- **Bidirectional GCS commands over Iridium MT (mobile-terminated)**. The
  current relay is MO-only. RockBLOCK supports MT; just hasn't been wired
  in this script.
- **Adaptive cadence based on flight phase**. Today's cadence is fixed
  by config; could derive from `MAVLink.MISSION_CURRENT` or
  `EXTENDED_SYS_STATE` to be aggressive only during cruise.
