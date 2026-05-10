---
title: Golden Image
layout: default
description: "Capture a fully-customized Jetson image post-first-boot and redeploy it bit-identical to N production units."
nav_order: 31
---

# Golden Image — Clone & Redeploy

Capture a fully-configured Jetson (kernel + apps + ROS + models + tuning) as a golden image; redeploy bit-for-bit to N units. Different from [Fleet]({{ '/FLEET' | relative_url }}) — that ships base firmware only; this ships the entire post-customization disk state.

## When to use which

| Flow | Captures | Distribute to | Use when |
|---|---|---|---|
| **`make release`** ([FLEET.md](FLEET.md)) | Base firmware (kernel + L4T rootfs + scripts) | Flash stations | First flashes; before any on-device customization |
| **`make clone-golden`** (this doc) | Entire NVMe state of a configured Jetson | Other Jetsons (post-validation) | After your golden Jetson is fully tested with apps, models, ROS graphs, and you want bit-identical clones |

You can use both in sequence: ship a release tarball to do the first
flash on the golden Jetson; then once it's validated, clone it and
ship that to the rest of the fleet.

## End-to-end workflow

```
┌──────────────────────────────────────────────┐
│ 1. Build & flash base image to Jetson #0     │
│      make ignite                              │
└──────────────────────────────────────────────┘
                   │
                   ▼
┌──────────────────────────────────────────────┐
│ 2. On Jetson #0 (the GOLDEN unit):           │
│      install Isaac ROS, models, packages     │
│      tune, fly, validate, soak-test           │
└──────────────────────────────────────────────┘
                   │
                   ▼
┌──────────────────────────────────────────────┐
│ 3. Power Jetson #0 off → APX recovery mode   │
└──────────────────────────────────────────────┘
                   │
                   ▼
┌──────────────────────────────────────────────┐
│ 4. From host:                                 │
│      make clone-golden TAG=v1.0-validated     │
│    → golden-images/golden-v1.0-validated-<ts>│
└──────────────────────────────────────────────┘
                   │
                   ▼
┌──────────────────────────────────────────────┐
│ 5. For Jetsons #1..N (recovery mode each):   │
│      make flash-golden GOLDEN=<name>         │
│         DEVICE=av-NN                         │
│    → bit-identical NVMe; first-boot           │
│      personalize_first_boot.sh assigns        │
│      unique hostname + SSH host keys          │
└──────────────────────────────────────────────┘
```

## Step 1 — capture

```bash
# Power off the validated Jetson, put it in APX recovery mode (short REC+GND,
# plug USB-C to the host), then:
make clone-golden TAG=v1.0-bench-validated

# Or directly:
./scripts/clone_golden.sh v1.0-bench-validated
```

The script:

1. Confirms the L4T tools tree is present (Phase 1 must have run at least
   once on this host).
2. Auto-detects APX (60s timeout, falls back to operator prompt).
3. Prefers NVIDIA's `l4t_backup_partitions.sh` if R36.5 ships it. Falls
   back to `l4t_initrd_flash.sh --read` for older trees.
4. Pulls back every partition image into
   `golden-images/golden-<TAG>-<TIMESTAMP>/`.
5. Writes `golden.manifest.json` (capture time, capturing user, source
   board target, BUILD_MANIFEST.json reference, git head) and
   `CHECKSUMS.sha256` (sha256 of every captured file).
6. Optionally signs the manifest with `GPG_KEY=YOURKEY`.

Each step is pre/post-verified through the same `step::run` framework
the rest of the pipeline uses. Logs go to `logs/<timestamp>_*.log`.

### Variant: capture from staged rootfs (no hardware)

If you just want a "snapshot the rootfs we just baked" archive — useful
for backing up before a risky modification — pass `--from-staged`:

```bash
./scripts/clone_golden.sh v1.0-baseline --from-staged
```

This captures `Linux_for_Tegra/rootfs/` as a tarball under the same
`golden-images/` directory. Re-flash uses `make flash` after restoring
the rootfs, not `make flash-golden` directly.

## Step 2 — list available goldens

```bash
make list-goldens
```

Prints every `golden-*/` directory with its tag, capture date, size,
and capture mode.

## Step 3 — redeploy to other Jetsons

For each receiving Jetson:

1. Power off, enter APX recovery mode.
2. From host:
   ```bash
   make flash-golden GOLDEN=golden-v1.0-bench-validated-<ts> DEVICE=av-07
   ```

The script:

1. Verifies `CHECKSUMS.sha256` against every file in the golden.
2. Verifies GPG signature if `golden.manifest.sig` is present and
   `gpg` is installed (set `GPG_VERIFY=0` to skip).
3. Auto-detects APX.
4. Stages the golden's images at `tools/kernel_flash/images/<board>/`
   where `l4t_initrd_flash.sh` expects them.
5. Runs `l4t_initrd_flash.sh --use-backup-image --external-device
   nvme0n1p1 …`.
6. Waits for the receiving Jetson to reboot (APX disappears).
7. Appends a row to `fleet_log.csv` with `result=FLASHED_FROM_GOLDEN`
   and the golden's manifest hash.

The receiving Jetson's first-boot service then runs
`personalize_first_boot.sh`, which:
- regenerates SSH host keys (so all clones don't share the keys baked
  in the golden),
- sets a unique hostname (from MAC if no `device.conf` was staged, or
  from `flash_batch.sh`'s per-device config),
- optionally writes a static IP via systemd-networkd.

So while the bytes are bit-identical at flash time, the device-specific
identity diverges immediately on first boot. **No SSH host-key
collisions.**

## Step 4 — validate the clone

Same as any other flash:

```bash
make verify          # SSH gauntlet against the receiving Jetson
ssh j@<ip> jetson-av-version
```

The clone should report the same `BUILD_MANIFEST.json` as the golden
(under `/etc/jetson-av-build.json`) plus its own `personalized` block
showing the unique hostname.

## Layout under `golden-images/`

```
golden-images/                                  ← gitignored
├── golden-v1.0-bench-validated-20260507-101200/
│   ├── golden.manifest.json
│   ├── CHECKSUMS.sha256
│   ├── golden.manifest.sig                     ← only if GPG_KEY was set
│   ├── boot.img                                ← partition images (sample)
│   ├── kernel.img
│   ├── system.img.raw
│   ├── system.img.gz
│   └── … (everything l4t_backup_partitions emitted)
└── golden-v1.0-baseline-20260507-093400/
    ├── golden.manifest.json                    ← capture_mode=staged
    ├── CHECKSUMS.sha256
    └── staged-rootfs.tar.gz                    ← no partition images; tarball only
```

## Storage size

A typical golden for this platform:

- Just-flashed base image: ~3 GB compressed.
- Fully customized (Isaac ROS + Nav2 + OpenCV-CUDA cache +
  models): ~8–14 GB.
- Tarball variant (`--from-staged`) is smaller because it excludes
  bootloader partitions.

`golden-images/` is gitignored. Treat the directory like a release
artifact store — keep on a fast NAS or S3 bucket if your fleet is large.

## What's NOT in a golden

- **Per-device identity**: hostname, SSH host keys, static IP — these
  are regenerated by `personalize_first_boot.sh` on every boot of every
  device. The golden carries the SSH keys of the original Jetson;
  those are deleted and regenerated at first boot of each clone.
- **Personalization config**: the `/etc/jetson-av-fleet/device.conf`
  the operator stages via `flash_batch.sh` is per-device, not golden.
- **Flight logs**: `/var/log/jetson-av/flights/` is on the btrfs data
  partition; consider whether you want to clone with or without past
  flight data. Today the golden captures whatever's on NVMe at
  capture time. Wipe before cloning if you want a clean slate:
  `ssh j@golden 'sudo rm -rf /var/log/jetson-av/flights/*'`.

## Troubleshooting

### `l4t_backup_partitions.sh: not found`

The R36.5 tree may not include this script in every BSP archive. The
clone script falls back to `l4t_initrd_flash.sh --read` automatically.
If the fallback also fails, verify the BSP is intact:

```bash
ls $L4T_DIR/tools/kernel_flash/l4t_initrd_flash.sh
ls $L4T_DIR/tools/backup_restore/        # may not exist on every R36.x
```

### Capture takes 30+ minutes

Reading every NVMe partition at USB 2.0 RNDIS speeds is slow. Expect
20–45 min for a 16 GB partition. The progress bar in the
`--showlogs` output is the most useful indicator. Don't kill the
process; resume isn't supported.

### Receiving Jetson boots with "host key changed" warnings

This means `personalize_first_boot.sh` didn't run (or didn't
regenerate keys). SSH in via password (if enabled) and:

```bash
sudo rm /etc/jetson-av-personalized
sudo /home/j/personalize_first_boot.sh
sudo reboot
```

### Clones share storage UUIDs

`mkfs.btrfs -L jetson-av-data` runs only at `install_data_partition.sh`
time. The golden carries the original UUID. If you have multiple
clones on the same network and need distinct UUIDs (rare):

```bash
ssh j@av-07 'sudo btrfstune -U $(uuidgen) /dev/nvme0n1pN'
```

### Disk space — golden-images/ filled up

Each capture is ~3–14 GB. After ~10 captures you'll be at ~100 GB.
Prune aggressively or move to S3:

```bash
make list-goldens                         # shows sizes
rm -rf golden-images/golden-old-*         # local prune
aws s3 sync golden-images/ s3://my-bucket/jetson-goldens/   # archive
```

## Provenance chain

For audit / compliance:

```
Source code → git commit → build → BUILD_MANIFEST.json
   ↓                                       ↓
release tarball → release.manifest.json → flashed to golden Jetson
                                                ↓
                                  on-device customization
                                                ↓
                              clone_golden → golden.manifest.json + CHECKSUMS + sig
                                                ↓
                                  flashed to fleet → fleet_log.csv per device
```

Every step has a manifest + sha256 + (optional) GPG signature. End-to-end
you can answer "what code is on av-07?" by following:

`fleet_log.csv` → golden manifest → release manifest → BUILD_MANIFEST.json → git_head

No black boxes.
