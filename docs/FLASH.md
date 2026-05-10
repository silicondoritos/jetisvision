---
title: Flash
layout: default
description: "Phase 4 flash mechanics: APX recovery mode, l4t_initrd_flash.sh invocation, NVMe targeting, and post-flash validation flow."
nav_order: 11
---

# Flash Guide

> **WARNING**: Flashing erases the target NVMe completely. Back up
> anything you need before proceeding.

## Standard flow

```bash
make audit               # gate — must be green before flashing
# … put Jetson in recovery mode (see below) …
make flash               # ~15–25 minutes
# … wait ~90 s for first-boot service to complete and reboot …
make verify              # post-flash gauntlet
```

Or end-to-end including the audit and verification:

```bash
make ignite              # doctor → all → audit → flash → verify
```

## Putting the Jetson in recovery mode

1. Power the Jetson **off** completely (pull USB-C; carrier board fully
   unpowered).
2. Locate the **REC** and **GND** pins/headers on the carrier board.
3. With the device unpowered, **short REC to GND** with a jumper or
   tweezers.
4. While holding the short, **plug USB-C** into the rear motherboard
   port. **No hub. No extender. No docking station.** USB-C cable
   should be ≤1 m and rated for data.
5. Hold the short for ~2 s after power-on, then release.
6. On the host: `lsusb | grep 0955:7323` — must show
   `NVIDIA Corp. APX`. If absent, repeat from step 1.

## What `make flash` does

`scripts/04_flash_nvme.sh`:

1. `cd latest_jetson/Linux_for_Tegra`.
2. Runs `sudo ./tools/l4t_flash_prerequisites.sh` — generates fused
   NVIDIA bootloader binaries (MB1, PSC_BL1, QSPI image).
3. Runs `sudo ./apply_binaries.sh` — copies fused binaries into the
   rootfs at the correct paths (kernel, initrd, DTBs).
4. **Pauses** with a `read -p` so you can confirm the Jetson is in
   recovery mode.
5. Installs a udev rule that names the NVIDIA RNDIS gadget `usb0`
   regardless of the host's existing network interfaces.
6. Runs `sudo ./tools/kernel_flash/l4t_initrd_flash.sh` with:
   - `--external-device nvme0n1p1`
   - `-c tools/kernel_flash/flash_l4t_t234_nvme.xml` (partition table)
   - `-p "-c bootloader/generic/cfg/flash_t234_qspi.xml"` (QSPI config)
   - `--showlogs` (verbose to terminal)
   - `--network usb0`
   - `jetson-orin-nano-devkit internal` (board + storage target)

The flash takes 15–25 min. The Jetson:

1. Boots into a minimal initrd from the host (RNDIS USB Ethernet).
2. Mounts the host's rootfs over NFS.
3. Writes NVMe partitions from the host-staged images.
4. Reboots into the new firmware.

## After flashing

1. Power off the Jetson.
2. **Remove the recovery jumper.** This is critical — if you don't, it
   will re-enter recovery on every boot.
3. Power on. The Jetson boots into the new firmware.
4. The `jetson-first-boot.service` runs:
   - `apt-mark hold` + Pin-Priority -1 for kernel/bootloader packages.
   - Installs the vermagic-aligned `linux-headers-*.deb` from
     `/opt/kernel-headers/`.
   - Builds `/opt/av-env` venv with `numpy<2.0.0`, PyTorch 2.7 (Jetson
     wheel), Voyager SDK 1.6 (pip wheels).
   - Runs `/opt/zed-sdk/install_zed_sdk.sh` if a `.run` was staged
     (`runtime_only` mode — DKMS path skipped; we own `sl_zedx.ko`).
   - Injects RT boot args into `/boot/extlinux/extlinux.conf`.
   - Touches `/home/j/.jetson_initialized` and signals reboot.
5. Reboot. The RT cmdline activates; `jetson-rt-tune.service` pegs
   clocks to MAXN, pins IRQs, applies all per-boot tuning.

## Validation

```bash
make verify
```

`scripts/05_post_flash_validate.sh` runs from the host. It:

1. Confirms ICMP and SSH reachability on `192.168.55.1`.
2. Runs `verify_tuning.sh` over SSH on the target — RT kernel,
   isolated cores, CMA, vermagic of mission-critical modules,
   cyclictest jitter < 100 µs.
3. Confirms `/usr/src/linux-headers-$(uname -r)/` is present (DKMS).
4. Imports `axelera.runtime`, `torch` (CUDA), `pyzed.sl` from
   `/opt/av-env`.

Exit 0 means the device is mission-ready. Exit 1 means investigate
(see `docs/RUNBOOK.md` §R6).

## Board target → nvpmodel table (L4T R36.5 / JetPack 6.2.2)

The flash config string, the module SKU, and the nvpmodel profile are three
independent things. This table shows how they relate on L4T R36.5.

| Flash board target | Module | Standard mode | Super Mode (JetPack 6.2+) |
|---|---|---|---|
| `jetson-orin-nano-devkit` | **Orin NX 16GB** (P3767-0000) | `nvpmodel -m 0` → MAXN 25 W / 100 TOPS | `nvpmodel -m 4` → MAXN_SUPER 40 W / 157 TOPS ¹ |
| `jetson-orin-nano-devkit` | Orin NX 8GB (P3767-0001) | `nvpmodel -m 0` → MAXN 20 W / 70 TOPS | no Super profile |
| `jetson-orin-nano-devkit` | Orin Nano 8GB (P3767-0003) | `nvpmodel -m 0` → MAXN 15 W / 40 TOPS | no Super profile |
| `jetson-orin-nano-devkit-super` | **Orin Nano Super 8GB** (P3767-0004) | `nvpmodel -m 0` → MAXN 25 W / 67 TOPS | different SKU — do not confuse |

¹ Orin NX 16GB Super Mode requires the carrier to supply the HV power rail at
  40 W sustained and a thermal solution rated for that TDP. Confirm `nvpmodel
  --available` for the exact profile index on your BSP — it can shift across
  L4T minor versions.

**Rule**: if your module is Orin NX 16GB (P3767-0000), always flash with
`jetson-orin-nano-devkit`. Never use `jetson-orin-nano-devkit-super` —
that is a different module SKU (Nano Super). Super Mode on NX is activated
at runtime via nvpmodel, not via the flash config.

## Recovery from a bad flash

- If the device fails to boot after flashing → re-enter recovery mode
  and re-flash.
- If `extlinux.conf` was overwritten by a later package upgrade →
  `sudo /home/j/jetson_first_boot.sh` re-injects RT args (idempotent
  after marker removal: `sudo rm /home/j/.jetson_initialized`).
- If a vermagic mismatch appears post-flash → never `insmod --force`.
  Re-flash from a clean rebuild. See `docs/VERMAGIC_STRATEGY.md`.

## Common errors

| Error | Cause | Fix |
|---|---|---|
| Hangs at "Waiting for target to boot-up" | RNDIS gadget not enumerated | `docs/RUNBOOK.md` §R5 |
| Error 3 / 202 | USB chain (hub, autosuspend) | direct port; `echo -1 > /sys/module/usbcore/parameters/autosuspend` |
| ECID blank | Jetson not in recovery mode | repeat the recovery procedure |
| Flash succeeds, no boot | Wrong board target | confirm `jetson-orin-nano-devkit internal` matches |

For the full failure-mode table see `docs/TROUBLESHOOTING.md` §F.
