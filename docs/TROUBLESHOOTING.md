---
title: Troubleshooting
layout: default
description: "Symptom-first failure-mode catalog: vermagic mismatches, PCIe enumeration failures, ZED X I2C errors, DDS latency, and more."
nav_order: 5
---

# Troubleshooting

Symptom → cause → fix.

## Build & integration

### B-1. Build fails with missing cross-compiler

- **Symptom**: `aarch64-buildroot-linux-gnu-gcc: command not found`.
- **Cause**: Phase 2 was launched on the host, not inside Docker.
- **Fix**: `make docker-build` once, then `make build` (the Makefile
  routes through Docker automatically when not running inside the
  container).

### B-2. `make build` fails at `bindeb-pkg` stage

- **Symptom**: `make[1]: dpkg-buildpackage: command not found` or similar.
- **Cause**: Headers `.deb` build needs Debian packaging tools.
- **Fix**: Add to `Dockerfile`: `apt-get install -y dpkg-dev fakeroot
  build-essential debhelper`. Already present in current image — if you
  rebuilt locally without this, `make docker-build` again.

### B-3. Vermagic mismatch in the build tree (Phase 2 fails the gate)

- **Symptom**: end-of-Phase-2 vermagic gate prints
  `[FAIL] Vermagic mismatches detected`.
- **Cause**: a module was built outside the kernel's `make modules`
  invocation (e.g., a vendor build script that called `make` against the
  wrong KDIR).
- **Fix**: rebuild from clean (`make clean && make extract && make build`).
  Check that the relevant plugin ran (`run_hook post_extract` in
  `01_extract_and_patch.sh`) and registered the driver in-tree via its
  Kconfig+Makefile shim.

### B-4. DTBO file empty (~0 bytes) or absent

- **Symptom**: `pre_flash_audit.sh` reports
  `ZED X Overlay: FAIL (Missing binary in rootfs)`.
- **Cause**: NVIDIA's `kernel-devicetree` build system silently skipped
  the `dtbo-y` target.
- **Fix**: `02_build_kernel.sh` now compiles the overlay directly via
  `cpp -DBUILDOVERLAY ... | dtc -@ -f`. Confirm Phase 2 ran the manual
  compile block (look for `ZED X overlay DTBO compiled` in the log).

## Flashing

### F-1. Flash hangs at "Sending mb1" or "Waiting for target to boot-up"

- **Symptom**: `l4t_initrd_flash.sh` polls forever; no progress past
  ~30 s.
- **Cause**: USB chain issue (hub, autosuspend, RNDIS not enumerating),
  or Jetson did not enter recovery mode.
- **Fix**:
  1. `lsusb -t` — Jetson must be on a direct motherboard port, not a hub.
  2. `lsusb | grep 0955:7323` — APX must be present (= recovery mode).
  3. `sudo sh -c 'echo -1 > /sys/module/usbcore/parameters/autosuspend'`.
  4. `sudo sh -c 'echo 200 > /sys/module/usbcore/parameters/usbfs_memory_mb'`.
  5. Reseat USB-C, re-short REC+GND, re-power.

### F-2. Flash succeeds but Jetson doesn't boot

- **Symptom**: After flash and recovery-pin removal, no HDMI, no SSH.
- **Cause**: extlinux.conf has duplicate or malformed lines from a
  partial bake.
- **Fix**: Re-run Phase 3 (`make bake`) — the script now defensively
  removes prior RT args and `OVERLAYS` lines before injecting fresh ones.
  Then `make flash` again.

## Vermagic / module loadability

### V-1. `Invalid module format` in dmesg

- **Symptom**: `dmesg | grep -i "invalid module format"` or a service
  fails because its driver isn't loaded.
- **Cause**: vermagic mismatch — a `.ko` whose vermagic doesn't match
  the running kernel's.
- **Fix**:
  1. Identify the offender: `for ko in /lib/modules/$(uname -r)/...
     /*.ko; do modinfo "$ko" | grep -H vermagic; done`.
  2. Confirm the running kernel's expectation: `cat /proc/version`.
  3. If a vendor `.deb` was installed post-flash (e.g. someone ran
     `apt install nvidia-l4t-kernel-modules`), re-flash from a clean
     build. APT pinning (`Pin-Priority: -1`) added by first-boot should
     prevent recurrence.
  4. See `docs/VERMAGIC_STRATEGY.md`.

### V-2. ZED SDK install fails to build sl_zedx.ko

- **Symptom**: `dkms install -m sl_zedx ...` fails with
  `Cannot find sources for kernel 5.15.x-tegra`.
- **Cause**: linux-headers-*.deb wasn't installed before the SDK
  installer ran.
- **Fix**: `dpkg -i /opt/kernel-headers/linux-headers-*.deb`, then
  re-run `/opt/zed-sdk/install_zed_sdk.sh`. If the .deb is missing
  entirely, re-run Phase 2 (`make build`) and re-bake (`make bake`).

### V-3. Loaded modules look fine but driver behaves wrong

- **Symptom**: `lsmod` shows the module, but downstream subsystems
  (V4L2 device, PCIe link) misbehave.
- **Cause**: per-symbol CRC drift (`CONFIG_MODVERSIONS=y` mismatch even
  though vermagic strings happen to match) — extremely rare but possible
  if someone built modules against a different kernel source tree with
  the same `LOCALVERSION`.
- **Fix**: Force-load is not allowed (`CONFIG_MODULE_FORCE_LOAD` is off).
  The only path is rebuild from a clean tree.

## Hardware

### H-1. `lspci` shows nothing for Axelera

- **Cause**: PCIe link training failed; the cold-boot `LINK_WAIT_MAX_RETRIES`
  patch is the most common culprit.
- **Fix**: Verify `pcie-designware.h` shows `LINK_WAIT_MAX_RETRIES 100`
  in the source tree, rebuild and re-flash. See
  `docs/KERNEL_PATCHES.md` §1.

### H-2. ZED X frames appear but stereo depth is wrong

- **Cause**: MAX96712 deserializer was selected instead of MAX9296.
- **Fix**: `docs/DRIVERS.md` §1.2 — "MAX9296 vs MAX96712 silent-corruption trap".

### H-3. cyclictest reports max latency > 1 ms

- **Cause**: RT boot args missing, governor wrong, or IRQs not pinned.
- **Fix**:
  1. `cat /proc/cmdline` must contain `isolcpus=1-5 nohz_full=1-5
     rcu_nocbs=1-5`.
  2. `cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor` must
     be `performance`.
  3. `sudo /home/j/jetson_rt_tune.sh` to re-apply per-boot tuning.

### H-4. Performance tanks mid-mission

- **Cause**: thermal throttling; check
  `cat /sys/class/thermal/thermal_zone*/temp` (millidegrees C).
- **Fix**: `jetson_rt_tune.sh` already pegs the fan at PWM 255. If you're
  still hitting >85°C, add active cooling.

## Logs

Include with any support request:

- **Kernel build**: `tail -2000 BUILD_LOG.md`.
- **Flash**: full `l4t_initrd_flash.sh --showlogs` output.
- **First-boot**: `journalctl -b 0 -u jetson-first-boot.service`.
- **Per-boot tune**: `journalctl -b 0 -u jetson-rt-tune.service`.
- **dmesg**: `dmesg --level=err,warn,crit,alert,emerg`.
- **Vermagic state**: `sudo /home/j/verify_tuning.sh` — full output.
