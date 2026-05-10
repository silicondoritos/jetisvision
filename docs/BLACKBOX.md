---
title: Black-Box
layout: default
description: "Hash-chained per-flight event log and NVENC-encoded ROS bag recorder for post-flight forensics and incident correlation."
nav_order: 21
---

# Black-Box Recorder

Per-flight: NVENC-encoded ROS 2 bag, hash-chained JSON event log, in-memory ring buffer with crash flush. Reconstruct sensor data and decisions from any point before an incident.

## Layout on disk

```
/var/log/jetson-av/flights/<YYYYMMDD-HHMMSS>/
├── flight-meta.json        ← static metadata (build, host, kernel, config)
├── events.jsonl            ← append-only structured event log
├── events.sha256           ← hash-chain for tamper evidence
└── bag/                    ← ros2 bag recording (mcap or sqlite3)
    └── flight_<n>.mcap
```

A new directory is created every time the service starts. Auto-rotation
when a flight exceeds `MAX_FLIGHT_SIZE` (default 2G).

## Event log structure

`events.jsonl` is one JSON object per line:

```jsonl
{"t":"2026-05-06T18:01:23Z","k":"blackbox.start","prev":"GENESIS","p":{"version":"1"}}
{"t":"2026-05-06T18:01:23Z","k":"ros2_bag.start","prev":"a3f9…","p":{"pid":1234,"topics":"/zed/zed_node/rgb …"}}
{"t":"2026-05-06T18:14:07Z","k":"external","prev":"b210…","p":{"src":"mavlink_wd","e":"heartbeat_lost","v":"7"}}
{"t":"2026-05-06T18:14:07Z","k":"blackbox.flush","prev":"c994…","p":{"reason":"signal"}}
```

- `t` — UTC ISO 8601
- `k` — kind (`blackbox.*`, `ros2_bag.*`, `external`)
- `prev` — sha256 of the previous line (chain)
- `p` — payload, schema depends on `k`

`events.sha256` mirrors the chain: each line is the sha256 of the
corresponding JSON line. Tampering with any past event invalidates the
chain from that point forward.

To verify the chain:

```bash
flight=/var/log/jetson-av/flights/20260506-180123
paste <(cat "$flight/events.jsonl") <(cat "$flight/events.sha256") \
  | awk '{
      vline = $0; sub(/[^\t]+$/, "", vline);
      printf "%s", vline | "sha256sum | awk \"{print \\$1}\"";
      close("sha256sum | awk \"{print \\$1}\"");
    }' | diff - "$flight/events.sha256"
```

(In practice you'll want a small Python helper — see
`scripts/verify_blackbox_chain.py` if it ships.)

## Configuration

`/etc/jetson-av/blackbox.conf`:

```sh
# Topics to record (space-separated). Empty = events only, no bag.
ROS_TOPICS="/zed/zed_node/rgb/image_rect_color /zed/zed_node/imu/data /mavros/global_position/raw /mavros/state /tf /tf_static"

# Where flights live.
FLIGHT_DIR=/var/log/jetson-av/flights

# In-memory ring buffer length (used by ROS bag's --max-cache-size).
RING_SECONDS=120

# Periodic flush interval to disk.
FLUSH_INTERVAL=30

# Max bytes per flight before rotating to a new subdir.
MAX_FLIGHT_SIZE=2G
```

`/etc/jetson-av/bag-qos.yaml` defines QoS overrides per topic. The
defaults match the typical ZED + MAVROS setup; tune for your stack:

```yaml
/zed/zed_node/rgb/image_rect_color:
  reliability: best_effort
  history: keep_last
  depth: 1
/mavros/state:
  reliability: reliable
  history: keep_last
  depth: 5
```

## NVENC video encoding

For high-rate camera topics, the ros2 bag records pre-encoded H.264 if
the upstream camera node publishes encoded frames. ZED SDK can publish
H.264 directly via NVENC; configure your `zed_camera.launch.py`:

```python
parameters=[{
    "general.svo_compression": 4,        # H.264 GPU encode
    "video.publish_compressed": True
}]
```

Then add the compressed topic in `ROS_TOPICS`:

```
ROS_TOPICS="/zed/zed_node/rgb/image_rect_color/h264 …"
```

This drops disk I/O by ~10× vs raw frames.

## Runtime control

The black-box runs as `jetson-blackbox.service`:

```bash
# Status
systemctl status jetson-blackbox.service

# Force an immediate disk flush (e.g., before powering off)
sudo kill -USR1 $(systemctl show jetson-blackbox -p MainPID --value)

# Restart (starts a new flight directory)
sudo systemctl restart jetson-blackbox.service

# View live events
tail -f /var/log/jetson-av/flights/$(ls -t /var/log/jetson-av/flights | head -1)/events.jsonl
```

The MAVLink watchdog automatically sends SIGUSR1 when the FCU heartbeat
is lost (see `UAV_RESILIENCE.md` §10), guaranteeing the seconds before
link loss are on disk.

## Other services emitting events

Any service can drop events into the chain via the named pipe
`/var/run/jetson-av-events`:

```bash
echo '{"src":"my_service","e":"sensor_dropout","v":"imu_x"}' \
    > /var/run/jetson-av-events
```

The black-box drains the pipe in the background; entries appear in the
event log with `k: "external"`. Currently emitting:

- `axelera_brownout_guard.sh` — `metis_lost`, `metis_recovered`,
  `power_cap_set`, `metis_rescan_ok`
- `mavlink_watchdog.sh` — `heartbeat_lost`, `heartbeat_recovered`,
  `mavros_missing`, `watchdog_died`

## Retention

`logrotate` is **not** applied to flights — they're append-only by design.
Implement a higher-level retention policy (e.g., a cron job that
archives old flights to long-term storage and deletes anything older
than 30 days) per your operational needs:

```bash
# /etc/cron.daily/jetson-av-flight-retention
#!/bin/sh
find /var/log/jetson-av/flights -mindepth 1 -maxdepth 1 -mtime +30 \
    -exec tar czf {}.tar.gz {} \; -exec rm -rf {} \;
find /var/log/jetson-av/flights -name '*.tar.gz' -mtime +90 -delete
```

## Bundling a flight for incident analysis

```bash
# Single flight
tar czf flight-20260506-180123.tar.gz -C /var/log/jetson-av/flights 20260506-180123

# Latest flight + system logs + manifests
make logs   # produces support-bundle-*.tar.gz at the repo root
```

## Verification

```bash
# Service alive?
systemctl is-active jetson-blackbox.service

# Recent events present?
ls -lh /var/log/jetson-av/flights/$(ls -t /var/log/jetson-av/flights | head -1)/

# Integrity check — compare checksums across flights for unexpected changes
sha256sum /var/log/jetson-av/flights/*/events.jsonl
```
