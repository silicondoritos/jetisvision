---
title: Quickstart
layout: default
description: "Zero to flashed Jetson Orin NX 16GB in 90 minutes: clone, stage tarballs, make doctor, make all, make flash, make verify."
nav_order: 2
---

# Quickstart

First build: follow every step. Repeat builds: use [Runbook]({{ '/RUNBOOK' | relative_url }}).

## Choose your path

This build has two independent layers. Decide upfront so you stage the right source trees.

| I want… | Path | Time |
|---|---|---|
| **Jetson + Metis + NVMe + Wi-Fi** — inference baseline, no camera, no ROS | Phases 1–4 only | ~90 min |
| **Full RT vision stack** — adds ZED X, Isaac ROS (cuVSLAM + nvblox + Nav2), resilience hardening | Phases 1–4, then 5 + 7 | ~90 min + ~2–3 h on-device |

**Baseline is complete after `make verify`.** You do not need ZED X driver source, a ZED SDK installer, or ROS to reach a working Metis inference image.

---

## Prerequisites

- Ubuntu 22.04 host, ≥16 GB RAM, ≥100 GB free disk
- Jetson Orin NX 16GB with NVMe SSD installed
- Axelera Metis M.2 in Key M slot
- USB-C direct to host (no hubs)
- *(Vision stack only)* ZED X + ZED Link Mono

## Step 0 — Clone

```bash
git clone https://github.com/silicondoritos/jetson-rt-stack.git
cd jetson-rt-stack
make help       # available targets
make versions   # pinned versions
```

## Step 1 — Host packages

```bash
sudo apt update
sudo apt install -y \
    build-essential bc bison flex git rsync zstd make openssl xxd \
    libssl-dev dpkg-dev qemu-user-static device-tree-compiler \
    nfs-kernel-server docker.io curl python3-pip

sudo usermod -aG docker $USER
newgrp docker

pip install kconfiglib    # required for make menuconfig / make defconfig
```

## Step 2 — Configure

```bash
make defconfig      # apply committed defaults (full stack: RT + ZED X Mono + Metis + MAXN_SUPER)
# or:
make menuconfig     # interactive TUI to customize options
```

See [Configuration]({{ '/CONFIGURATION' | relative_url }}) for all available options.

## Step 3 — Stage source tarballs and vendor trees

Place NVIDIA tarballs as siblings of the repo root:

```
jetson-rt-stack/
Jetson_Linux_R36.5.0_aarch64.tbz2
Tegra_Linux_Sample-Root-Filesystem_R36.5.0_aarch64.tbz2
public_sources.tbz2
```

**NVIDIA tarballs**: [developer.nvidia.com/embedded/jetson-linux-archive](https://developer.nvidia.com/embedded/jetson-linux-archive) → JetPack 6.2.2 / L4T R36.5.0. All archives live under `r36_release_v3.0/` on the CDN. Exact pin — do not substitute 6.0 or 6.1.

Vendor trees — place adjacent to the repo root:

```
jetson-rt-stack/
axelera-driver/      ← Axelera Metis kernel driver (NDA — contact Axelera support)
voyager-sdk/         ← Axelera Voyager SDK + axl-jetson.patch (NDA — same package)
zedx-driver/         ← Stereolabs ZED X kernel driver (NDA — contact Stereolabs support)
zed-sdk/             ← ZED SDK installer (public — stereolabs.com/developers/release)
  └── ZED_SDK_Tegra_*.run
```

**`axelera-driver/` and `voyager-sdk/`** are required for the Metis baseline. **`zedx-driver/` and `zed-sdk/`** are required for the full RT vision stack. To build without camera or ZED SDK: set `CAMERA_NONE=y` in `make menuconfig`. See [Drivers]({{ '/DRIVERS' | relative_url }}) for acquisition instructions.

## Step 4 — Preflight

```bash
make doctor
```

Prints PASS/FAIL/WARN for every prerequisite. Read-only — modifies nothing. Fix all FAILs before continuing.

## Step 5 — Build container (one-time)

```bash
make docker-build
```

~5 min. Ubuntu 22.04 + Bootlin aarch64 toolchain. Only needed again if the Dockerfile changes.

## Step 6 — Build firmware

```bash
make all    # extract → build → bake  (~45–90 min)
```

1. **Extract** — unpacks L4T tarballs, runs plugin hooks (vendor source injection, patches, in-tree shim creation, defconfig additions).
2. **Build** — cross-compiles kernel + modules + `linux-headers-*.deb` inside Docker. Captures vermagic. Hard-fails on module mismatch.
3. **Bake** — stages vendor SDKs, ISP calibrations, udev rules, systemd services, RT boot args, and `power.conf` into rootfs.

## Step 7 — Pre-flash audit

```bash
make audit
```

Do not flash if this shows red.

- DTBO missing → re-run Phase 2
- Vermagic mismatch → `make clean && make all`

## Step 7 — Recovery mode

1. Power Jetson off.
2. Short REC and GND on the carrier.
3. Plug USB-C directly into the host (no hub, no extender).
4. Hold ~2 s, release.
5. Verify: `lsusb | grep 0955:7323` must show `NVIDIA Corp. APX`.

## Step 8 — Flash

```bash
make flash    # 15–25 min
```

When done:
1. Power off.
2. Remove recovery jumper.
3. Power on. First-boot service runs ~3–5 min then reboots.
4. After reboot: RT cmdline active, `jetson-rt-tune.service` locks clocks to MAXN.

## Step 9 — Verify (baseline complete)

```bash
make verify
```

Checks (via SSH to `192.168.55.1`):

**Baseline — always checked:**
- SSH reachable
- `uname -r` ends in `-tegra`
- `cat /sys/devices/system/cpu/isolated` = `1-5`
- Metis on PCIe (`1f9d:1100`), module loaded, vermagic match
- CMA heap ~2 GB
- `nvpmodel -q` = MAXN
- cyclictest 10 s on isolated cores 1–5 → p99 max < 100 µs (full test conditions: [RT tuning]({{ '/RT_KERNEL_OPTIMIZATION' | relative_url }}))
- `axelera.runtime` importable from `/opt/av-env`

**RT vision extension — checked when camera is configured:**
- ZED X driver loaded, vermagic match
- `pyzed.sl` importable from `/opt/av-env`

All baseline checks green → **Layer 1 complete.** The Jetson is ready for Metis inference.

---

## Next: Layer 2 — RT vision extension (optional)

Install after `make verify` passes, over SSH or on the device directly:

```bash
# Phase 5: ROS 2 + Isaac ROS + OpenCV-CUDA  (~2–3 h, first time)
sudo bash /home/j/phase5/install_av_phase5.sh

# Phase 7: hardening — watchdog, brownout guard, PCIe AER monitor  (~15 min)
sudo bash /home/j/phase7/install_uav_phase7.sh
```

Or set `SKIP_PHASE5=0` before first-boot if scripts are already staged, to let them run automatically.

See [AV Stack]({{ '/AV_STACK' | relative_url }}) and [Platform Resilience]({{ '/UAV_RESILIENCE' | relative_url }}) for details.

---

## One-shot

```bash
make ignite-no-flash    # doctor → all → audit  (no hardware needed)
make ignite             # doctor → all → audit → flash → verify
```

`ignite` prompts before flashing and waits 90 s post-flash for first-boot to complete.

## Failures

- Build → [Troubleshooting]({{ '/TROUBLESHOOTING' | relative_url }}) §B
- Flash → [Troubleshooting]({{ '/TROUBLESHOOTING' | relative_url }}) §F
- Vermagic → [Vermagic strategy]({{ '/VERMAGIC_STRATEGY' | relative_url }})
- Support bundle: `make logs` → `support-bundle-YYYYMMDD-HHMMSS.tar.gz`
