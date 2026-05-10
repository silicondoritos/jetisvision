---
title: Data Partition
layout: default
description: "Single-NVMe btrfs data partition with zstd:3 compression, weekly scrub timer, and snapshot strategy for data integrity."
nav_order: 22
---

# Durable Data Partition

btrfs on a single NVMe: bit-rot detection, `zstd:3` compression, atomic snapshots. Installed by `scripts/install_data_partition.sh`. RAID 1 is the next step up; single-drive is what ships today.

## What you get on a single NVMe

| Property | Mechanism |
|---|---|
| Bit-rot detection | btrfs block-level CRC32C on data + metadata; mismatch → I/O error, not silent corruption |
| Compression | `compress=zstd:3` mount option — typical 2× for ROS bags / JSONL event logs / dmesg |
| Atomic snapshots | btrfs subvolume snapshot — capture a flight's state in O(1), no copy |
| Periodic scrub | systemd timer `jetson-av-btrfs-scrub.timer` runs `btrfs scrub start` every Sunday at 03:00 (randomized) |
| No-atime | Logs don't bump access timestamps → less write amplification on the SSD |

What you **do not** get: redundancy across drives. A bad block in btrfs on
one drive is still data loss for that block. With two drives → `DATA_RAID=1`
→ btrfs raid1 mirrors data + metadata and self-heals on scrub. That's a
TODO once a second NVMe is added.

## Layout

```
/var/log/jetson-av/
├── data/                                ← btrfs mount (subvolume capable)
│   └── flights/                         ← subvolume; per-flight subdirs
│       ├── 20260506-180123/
│       │   ├── flight-meta.json
│       │   ├── events.jsonl
│       │   ├── events.sha256
│       │   └── bag/flight_0.mcap
│       └── 20260506-191040/
└── flights → data/flights               ← symlink (compat with jetson_blackbox.sh)
```

## Two install modes

`install_data_partition.sh` decides automatically:

### Mode A — partition (preferred)

If `>100 GB` of free space exists at the end of `/dev/nvme0n1`:

1. `parted` adds a primary partition at the tail.
2. `mkfs.btrfs -L jetson-av-data /dev/nvme0n1pN`.
3. Mount at `/var/log/jetson-av/data` with
   `compress=zstd:3,noatime,space_cache=v2,autodefrag`.
4. fstab entry by UUID.

This is the right choice when the L4T flash didn't fill the whole SSD.

### Mode B — loop file (fallback)

If the SSD is fully consumed by other partitions:

1. `truncate -s 200G /opt/jetson-av-data.btrfs` (sparse — only takes disk
   as data is written).
2. `mkfs.btrfs -L jetson-av-data /opt/jetson-av-data.btrfs`.
3. Mount with `loop,compress=zstd:3,…` at the same mount point.
4. fstab entry by file path.

A loop file is slightly slower than a real partition, but for write-heavy
sequential workloads (ROS bags, JSONL) the difference is <5% and below
black-box throughput requirements.

## Tunables (env vars)

```bash
NVME_DEV=/dev/nvme0n1            # which drive to operate on
MOUNT_POINT=/var/log/jetson-av/data
LOOP_FILE=/opt/jetson-av-data.btrfs
LOOP_SIZE_GB=200
MIN_FREE_GB=100                  # threshold above which a partition is created
SCRUB_DAY=Sun                    # weekly scrub day
```

Override at install time:

```bash
sudo MIN_FREE_GB=50 LOOP_SIZE_GB=100 /home/j/phase7/install_data_partition.sh
```

## Verify

```bash
# Filesystem level
btrfs filesystem df /var/log/jetson-av/data
btrfs filesystem usage -h /var/log/jetson-av/data

# Scrub state
btrfs scrub status /var/log/jetson-av/data
systemctl list-timers | grep jetson-av-btrfs

# Snapshot a flight on demand
sudo btrfs subvolume snapshot -r \
    /var/log/jetson-av/data/flights/<id> \
    /var/log/jetson-av/data/flights/<id>.snap
```

## Upgrade path: add a second drive

When a second NVMe is wired, the same script will (in a future revision)
support `DATA_RAID=1`:

```bash
sudo NVME_DEV2=/dev/nvme1n1 DATA_RAID=1 \
     /home/j/phase7/install_data_partition.sh
```

This will:

1. Add the second drive as a btrfs device: `btrfs device add /dev/nvme1n1 …`.
2. Convert data + metadata to raid1: `btrfs balance start
   -dconvert=raid1 -mconvert=raid1 …`.
3. Verify via a scrub — corrupt blocks now self-heal from the mirror.

Existing data is preserved; it's an in-place conversion.

## What lives where

| Path | What | Backed up by |
|---|---|---|
| `/var/log/jetson-av/data/flights/` | Per-flight forensic dirs | btrfs snapshot, scrub |
| `/var/log/jetson-av/*.log` (above the mount) | Service logs | logrotate |
| `/var/log/journal/` | systemd journal | journald `SystemMaxUse=2G` |
| `/etc/jetson-av/` | Configuration | static; restored at next bake |
| `/opt/av-env/` | Python venv | first-boot recreates |

## Failure modes

### "btrfs: bdev … errs: …"

A bit-rot was detected. Mid-flight: the I/O is a hard error (data isn't
silently corrupt). Post-flight: `btrfs scrub status` shows the count.
Replace the SSD before next mission.

### Mount point gone after reboot

fstab entry missing or device UUID changed. Re-run:

```bash
sudo /home/j/phase7/install_data_partition.sh
```

It detects the existing btrfs and just re-writes fstab.

### Scrub takes too long

Default scrub runs at `IOSchedulingClass=idle` so it shouldn't impact a
flight, but on a packed SSD a full scrub can take hours. Move to monthly:

```bash
sudo sed -i 's|OnCalendar=.*|OnCalendar=monthly|' \
    /etc/systemd/system/jetson-av-btrfs-scrub.timer
sudo systemctl daemon-reload
```
