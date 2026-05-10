---
title: RT Tuning
layout: default
description: "PREEMPT_RT tuning recipes: cyclictest methodology, CPU isolation parameters, IRQ affinity, scheduler tuning, and expected jitter numbers."
nav_order: 15
---

# RT Kernel Optimization

Tuning loop for Jetson Orin NX running L4T R36.x: low-latency, low-jitter workloads (capture → inference). Measure → diagnose → change → verify.

**Scope**
- Hardware: Jetson Orin NX / Nano (P3767 / P3766)
- BSP: L4T R36.5.x
- Tools: Docker build env + `scripts/` + physical Jetson
- Inputs: kernel source at `latest_jetson/Linux_for_Tegra/source/kernel/`, `voyager-sdk/axl-jetson.patch`, patches in `zedx-driver/`
- Output: `CONFIG_*` + boot args + runtime recipe with measurable jitter reduction

## Documented test conditions for the < 100 µs target

The `make verify` gate requires p99 max cyclictest latency < 100 µs on isolated cores. The exact conditions for that target:

| Parameter | Value |
|---|---|
| Kernel | 5.15-tegra (PREEMPT_RT) |
| nvpmodel | 4 (MAXN_SUPER, 40 W) |
| jetson_clocks | locked (all clocks at max) |
| CPU governor | performance |
| Isolated cores | 1–5 (`isolcpus=1-5 nohz_full=1-5`) |
| Concurrent load | Metis inference (Voyager axrun) + ZED X CSI capture (if driver loaded) |
| cyclictest flags | `--smp --mlockall --priority=99 --affinity=1-5 --threads --interval=200 --duration=10` |
| Reported metric | p99 max (max latency output of cyclictest across all measured threads) |
| Duration | 10 seconds |
| Ambient temperature | ~25 °C lab bench |
| Airflow | natural convection (no forced airflow) |

**Limitations**: 10 s is a smoke test. Production deployments should run ≥ 30 min at operating temperature with a full mission load (cuVSLAM + Isaac ROS + Nav2). The 100 µs gate is a go/no-go check, not a performance specification. Long-tail outliers (p99.9+) will be higher, especially under thermal load.

Reproduce:

```bash
# On the Jetson, as root, after jetson_clocks and nvpmodel -m 0
sudo cyclictest --smp --mlockall --priority=99 --affinity=1-5 \
    --threads --interval=200 --duration=10 --histofall --json=/tmp/ct.json
```

Key success criteria
- p99 max < 100 µs on isolated cores under concurrent inference + capture load (smoke test; 10 s).
- No recurring high-latency outliers after 30 min load testing (stress-ng CPU & memory on non-isolated cores + mission workload on isolated).
- rtla / timerlat traces point to eliminated major kernel-induced latency sources.

High-level strategy
1. Enable PREEMPT_RT in kernel config and apply any vendor patches (Axelera `axl-jetson.patch` already modifies defconfig in this repo).
2. Enable temporary tracing build options for diagnostics (only for debugging runs): CONFIG_TRACING, FTRACE, TIMERLAT, HWLAT, OSNOISE tracers.
3. Build & boot the RT kernel in the device rootfs (use the repo `scripts/02_build_kernel.sh` and `03_bake_rootfs.sh`).
4. Run measurement: cyclictest and rtla timerlat / rtla osnoise to find hotspots.
5. Tune kernel config and boot args (NO_HZ_FULL, rcu_nocbs, isolcpus, nohz_full, CPU governor, irqaffinity, disable problematic kthreads, disable dynamic freq governors).
6. Rebuild, re-measure, iterate until targets met. Remove diagnostic tracing options from final defconfig to minimize overhead.

Important kernel config options (set in defconfig or via menuconfig)
- `CONFIG_PREEMPT_RT=y` — core RT support; threads IRQs and preemptible locks.
- CONFIG_NO_HZ_FULL = y — full dynticks for isolated CPUs to reduce tick noise.
- CONFIG_HIGH_RES_TIMERS = y
- CONFIG_HZ_1000 (or appropriate HZ) — consider 1000Hz for finer timer resolution; test for your workload.
- CONFIG_RCU_NOCB_CPU — ensure support for rcu callbacks on threads; configure `rcu_nocbs` boot arg to move callbacks off isolated CPUs.
- CONFIG_PREEMPTIRQ_EVENTS (ensure preempt IRQ offload where supported by RT patches)
- Tracing (enable only while debugging): CONFIG_TRACING, CONFIG_FTRACE, CONFIG_OSNOISE_TRACER, CONFIG_HWLAT_TRACER, CONFIG_TIMERLAT_TRACER.

Recommended boot arguments (extlinux/extlinux.conf or U-Boot kernel args)
- `isolcpus=1-5 nohz_full=1-5 rcu_nocbs=1-5` — dedicate CPUs 1–5 to RT tasks (this build's isolation set).
- threadirqs (if supported / per-vendor guidance) — force threaded IRQs (RT moves most IRQ handlers to threads).
- nosoftirqwq (if testing indicates workqueue interference) — optional and risky; prefer targeted fixes.
- mitigations=off — optional (security/perf tradeoff). Only use with risk awareness.

Jetson-specific runtime knobs
- nvpmodel: pick the correct power/perf profile (e.g., `sudo nvpmodel -m 0` for max performance) before measurements.
- jetson_clocks: `sudo jetson_clocks --store` then `sudo jetson_clocks` to lock clocks; restores after tests.
- CPUfreq governor: set to `performance` for non-isolated CPUs and pinned RT cores. Example:

```bash
sudo apt install cpufrequtils  # if needed
sudo cpufreq-set -r -g performance
# or write 'performance' to /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor
```

- Disable dynamic userspace power management (autosleep/autosuspend) for devices that cause interrupts (PCIe devices):

```bash
# Example: disable autosuspend globally
echo -1 | sudo tee /sys/module/usbcore/parameters/autosuspend
```

CPU isolation, IRQ affinity, and kthread management
- Isolate CPUs using `isolcpus=` kernel arg and move non-essential kernel threads off isolated cores (use `tuna` or `taskset` to move tasks).
- Prevent IRQs from landing on isolated cores: set `/proc/irq/<irq>/smp_affinity` to mask those cores. Example to move NIC interrupts:

```bash
# list IRQs and their handlers
grep . /proc/irq/*/smp_affinity_list
# set affinity (hex mask) to CPU0 and CPU1 (example)
echo 3 | sudo tee /proc/irq/<IRQ_NUMBER>/smp_affinity
```

- For Jetson-specific devices (Axelera Metis, ZED X), after the driver is loaded, verify device IRQs and move them to non-isolated CPUs.

Trace & diagnose (measurement recipes)
- Install test & tracing tools on target (or in chroot while baking rootfs):

```bash
sudo apt update
sudo apt install -y rt-tests rtla trace-cmd perf sysstat stress-ng
```

- Run cyclictest on isolated cores 1–5:

```bash
# run as root for realtime priorities
cyclictest --smp --mlockall --priority=99 --affinity=1-5 --threads --interval=200 --histfile=hist.txt --json=results.json --runtime=60
```

- Run rtla timerlat simultaneously to capture stack traces for spikes above threshold (choose threshold from cyclictest max):

```bash
# run in separate shell; tune --auto and threshold
rtla timerlat top --cpus 1-5 --auto 250
# when a hit occurs, run:
rtla timerlat hit stop tracing
# saved traces are written to timerlat_trace.txt
```

- Use `rtla osnoise` and `rtla hwlat` for broader 'OS noise' and hardware-related latency sources.

Diagnostic interpretation & common causes
- CPUfreq / ondemand governor callbacks (od_dbs_update, dev_pm_opp_set_rate) — fix by using `performance` governor or disabling ondemand.
- Workqueue / kworker interference — identify via rtla traces; consider pushing work to specific cores or throttling.
- IRQ handlers executing long sections on isolated cores — move IRQ affinity away or request threaded IRQs.
- Power-management governor and device regulator calls — set performance profiles (nvpmodel/jetson_clocks) and pin OPPs when real-time is needed.

Kernel build & workflow notes (repo-specific)
- `scripts/01_extract_and_patch.sh` applies `voyager-sdk/axl-jetson.patch` and Stereolabs patches to the L4T kernel tree. Confirm the defconfig includes RT and other options added by patches:

```bash
DEFCONFIG=latest_jetson/Linux_for_Tegra/source/kernel/kernel-jammy-src/arch/arm64/configs/defconfig
grep -E "PREEMPT_RT|NO_HZ_FULL|RCU_NOCB|TIMERLAT|HWLAT|TRACING" "$DEFCONFIG" || true
```

- Build flow: `make Image dtbs modules` via `scripts/02_build_kernel.sh`, then `sudo ./tools/l4t_update_initrd.sh` to update initrd and `scripts/03_bake_rootfs.sh` to copy runtime components.

Testing matrix and edge cases
- Run cyclictest with and without system load (stress-ng pinned to non-isolated cores) to validate behavior under contention.
- Test with system services disabled (e.g., systemd services) to isolate software noise sources.
- Edge case: enabling tracing options (CONFIG_TRACING, TIMERLAT) adds overhead — remove them in production builds.
- Edge case: disabling security mitigations (mitigations=off) may be unacceptable for production systems.

Example tuning loop (concrete)
1. Patch defconfig: ensure PREEMPT_RT and NO_HZ_FULL; add debug tracers only for measurement builds.
2. Build kernel and modules (via repo scripts), flash or boot into the new kernel.
3. On target: nvpmodel -m 0; sudo jetson_clocks; set cpufreq governor to performance; pin RT task to isolated cores.
4. Run `cyclictest` to record baseline (save hist file). Run `rtla timerlat` to capture stack traces for spikes.
5. Inspect traces: identify offending kernel subsystems and adjust config (e.g., move IRQs, disable ondemand, adjust workqueue behavior).
6. Rebuild kernel with changes and repeat until satisfied. Remove tracing options in final build.

Useful commands summary

```bash
# Verify defconfig flags
grep -E "PREEMPT_RT|NO_HZ_FULL|RCU_NOCB|TIMERLAT|HWLAT|TRACING" $DEFCONFIG

# Set power profile and lock clocks
sudo nvpmodel -m 0
sudo jetson_clocks

# Set governors
for cpu in /sys/devices/system/cpu/cpu[0-9]*; do echo performance | sudo tee $cpu/cpufreq/scaling_governor; done

# Run cyclictest (example)
sudo cyclictest --smp --mlockall --priority=99 --affinity=2,3 --threads --interval=200 --histofall --runtime=60

# Run rtla timerlat in parallel
sudo rtla timerlat top --cpus 2,3 --auto 250

# Move IRQ affinity (example)
echo 3 | sudo tee /proc/irq/<IRQ>/smp_affinity
```

References and provenance
- Dataplugs: "Fine-Tuning Linux Kernel for Ultra-Low Latency Environments" — high-level kernel and system tuning strategies (govs, isolcpus, THP, hugepages, IRQ affinity).
- The Good Penguin: RTLA walkthrough, cyclictest recipes, and how to use `rtla timerlat` to find kernel-level latency causes; practical examples for ARM/embedded systems.
- NVIDIA Jetson Linux Developer Guide R36.5: device-specific guidance, nvpmodel and jetson_clocks usage, and kernel/flash workflow.

