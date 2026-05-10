---
title: Fine-Tuning
layout: default
description: "Cross-component coordination: power.conf, storage.conf, CPU affinity map, per-device CMA strategy, and axrun configuration."
nav_order: 18
---

# Fine-Tuning — Cross-Component Coordination

Per-component tuning: [Platform Resilience]({{ '/UAV_RESILIENCE' | relative_url }}) · [Kernel options]({{ '/KERNEL_OPTIMIZATIONS' | relative_url }}) · [Drivers]({{ '/DRIVERS' | relative_url }}).

Cross-component knobs: how Metis, ZED X, NVMe, GPU, and CPU coexist without contending on deadlines, memory bandwidth, or power budget.

Config files are written at install time. Which ones exist depends on which phases are installed:

| Config file | Written by | Layer |
|---|---|---|
| `/etc/jetson-av/power.conf` | Phase 4 first-boot / Phase 7 | **Baseline** — read by `jetson_rt_tune.sh` |
| `/etc/jetson-av/storage.conf` | Phase 7 (`install_data_partition.sh`) | **Baseline-useful** |
| `/etc/jetson-av/expectations.conf` | Phase 7 (`install_uav_resilience.sh`) | **Baseline-useful** |
| `/etc/jetson-av/blackbox.conf` | Phase 7 (`install_blackbox.sh`) | AV-specific |

Defaults target a 7–8 kg multirotor. For a bench inference workload, only `power.conf` and `storage.conf` are relevant.

---

## 1. Coordinated power budget — `/etc/jetson-av/power.conf` *(baseline)*

Single source of truth read by **both** `jetson_rt_tune.sh` (baseline, every boot)
and `axelera_brownout_guard.sh` (Phase 7). Total power = Jetson + Metis must
stay below your sustained DC-DC rail capacity.

```sh
NVPMODEL_MODE=4          # 4=MAXN_SUPER(40W,157TOPS) | 0=MAXN(25W) | 1=15W | 2=10W on Orin NX 16GB
GPU_MAX_FREQ_HZ=         # empty=HW max; cap (e.g. 800000000) protects EMC for Metis
EMC_FREQ_HZ=             # empty=HW max
LOCK_CPU_GOV=performance # ondemand | schedutil | conservative | performance
FAN_PWM=255              # 0-255
AXELERA_POWER_LIMIT_W=18 # Metis cap; datasheet peak ~23W; 18W gives headroom
```

Reference budgets:

| Profile | NVPMODEL | Metis cap | GPU | Total typical | Total peak |
|---|---|---|---|---|---|
| **Default** | 4 (MAXN_SUPER 40 W) | 18 W | uncapped | ~45 W | ~65 W |
| Conservative (smaller PSU) | 1 (15 W) | 15 W | 800 MHz cap | ~22 W | ~33 W |
| Bench / wall-powered | 0 (MAXN 25 W) | 23 W (no cap) | uncapped | ~38 W | ~55 W |

If `cuVSLAM` saturates LPDDR5 and Metis inference latency degrades, set
`GPU_MAX_FREQ_HZ=800000000` to leave EMC bandwidth headroom for the NPU.

## 2. NVMe write cache — `/etc/jetson-av/storage.conf`

```sh
NVME_VWC=off             # off=durable | on=fast | skip=device default
```

`off` flips NVMe Volatile Write Cache via `nvme set-feature -f 6 -v 0`.
Costs ~2× sequential write throughput; gains data durability across
sudden power-cut. **For black-box mode you want this OFF.**

A udev rule applies the policy on every NVMe enumeration so it survives
reboots. Verify with `nvme get-feature /dev/nvme0 -f 6 -H`.

## 3. CPU affinity map — what runs on which core

**Baseline cores** (set by `jetson_rt_tune.sh` on every boot, Phases 1–4):

| Core | Owner | Mechanism |
|---|---|---|
| 0 | OS, NVMe IRQs, watchdog | `irqaffinity=0` boot arg + per-IRQ pin |
| 1 | Metis IRQs + inference process | `jetson_rt_tune.sh` IRQ pin + `axrun` (default) |

**RT vision extension cores** (set by `launch_av_mission.sh`, Phase 5):

| Core | Owner | Mechanism |
|---|---|---|
| 2 | ZED X CSI/VI IRQs + camera capture | `jetson_rt_tune.sh` IRQ pin |
| 3 | nvblox 3D mapping | `launch_av_mission.sh` `AllowedCPUs=3` |
| 4-5 | cuVSLAM | `launch_av_mission.sh` `AllowedCPUs=4-5` + `axrun --slam` |
| 6-7 | Nav2, management | Default scheduler placement |

Isolation is enforced by `isolcpus=1-5 nohz_full=1-5 rcu_nocbs=1-5` boot
args. **Every** Tegra IRQ source NOT explicitly pinned to a specific
core falls through to the default-affinity mask `0xC1` (cores 0, 6, 7),
keeping cores 1-5 RT-clean. Patterns covered by the broad sweep:
`tegra-csi`, `tegra-capture-vi`, `vi-notif`, `host1x`, `nvenc`, `nvdec`,
`isp[0-9]?`, `mipi-cal`, `vic`, `nvgpu`, `nvjpg`, `nvgr`, `tegra-vi`,
`t234-cbb`, NVMe, Axelera.

### `axrun` — pinned execution wrapper for ad-hoc runs

```bash
# default: core 1 (Metis), no RT priority, OOM-shielded
axrun python detect_metis.py /path/to/yolo.ax

# SLAM profile: cores 4-5
axrun --slam ros2 launch isaac_ros_visual_slam isaac_ros_visual_slam.launch.py

# Real-time priority for hard-deadline loops
axrun --rt --cpu 1 ./hard_realtime_loop

# No OOM shield (e.g. debug runs)
axrun --no-oom-shield python -i interactive_debug.py
```

`launch_av_mission.sh` already pins via `systemd-run --scope -p
AllowedCPUs=…`; `axrun` is for shell / debug / one-off invocations so the
inference process can't accidentally land on a non-isolated core.

## 4. Mission expectations — `/etc/jetson-av/expectations.conf`

Different airframes carry different drivers. The expectations file lets
the verifier loud-fail when something **expected** is missing, while
silently passing when an intentionally-absent component reports as
unloaded.

```sh
EXPECT_METIS=1           # Axelera Metis M.2 expected
EXPECT_ZED_X=1           # Stereolabs ZED X expected
EXPECT_MAX9296=1         # GMSL2 deserializer (implied by ZED_X=1)
```

Default = expect all three (the full-payload configuration). On a botany-only
airframe with the MicaSense Altum-PT (no ZED X), set `EXPECT_ZED_X=0`
before flashing. Read by `verify_tuning.sh` post-boot.

## 5. PCIe AER (Advanced Error Reporting)

Enabled at the kernel level (`CONFIG_PCIEPORTBUS=y`, `CONFIG_PCIEAER=y`,
`CONFIG_PCIE_DPC=y`, `CONFIG_PCIEAER_INJECT=m`). The
`jetson-av-pcie-aer-monitor.service` polls
`/sys/bus/pci/devices/*/aer_dev_{correctable,fatal,nonfatal}` every 5 s
and emits a black-box event on any counter increase.

| Event kind | What it means | Severity |
|---|---|---|
| `aer_correctable` | Bit-flip on the link, recovered by retry | Low — log + monitor trend |
| `aer_nonfatal` | Transaction lost but device still functional | Medium — likely PCIe retrain visible in dmesg |
| `aer_fatal` | Link down or device removal | High — Metis/NVMe likely gone too |

Correlate with brownout-guard `metis_lost` events in the per-flight
`events.jsonl` to distinguish "Metis disappeared due to electrical sag"
from "Metis disappeared due to driver fault".

## 6. Vermagic-on-every-loaded-`.ko`

`verify_tuning.sh` walks the entire `/lib/modules/$(uname -r)/` tree,
not just the three mission-critical modules. Catches partial drift —
e.g., somebody runs `apt install` for a sidecar driver and the resulting
`.ko` mismatches our PREEMPT_RT vermagic.

## 7. Per-device CMA (deferred — single global pool today)

Today, ZED X capture buffers and Metis inference buffers both pull from
a single 2 GB `/dev/dma_heap/linux,cma` pool. Under sustained 4K stereo
+ inference load, fragmentation can occur (visible as `CmaFree` falling
faster than `CmaTotal-CmaUsed` would suggest).

**The fix when needed**: per-device CMA regions in the device tree.
Tegra DT supports `memory-region` properties pointing at reserved-memory
nodes per device. Sample overlay sketch (not yet auto-applied):

```dts
/ {
    reserved-memory {
        zedx_cma: zedx_cma {
            compatible = "shared-dma-pool";
            reusable;
            size = <0x0 0x48000000>;   // 1.2 GB for camera capture
            alignment = <0x0 0x10000>;
            linux,cma-default;
        };
        metis_cma: metis_cma {
            compatible = "shared-dma-pool";
            reusable;
            size = <0x0 0x32000000>;   // 0.8 GB for Metis inference
            alignment = <0x0 0x10000>;
        };
    };

    // Reference from ZED X node:
    // zedx@x { memory-region = <&zedx_cma>; };
    // Reference from Metis (if its driver supports DT memory-region):
    // axelera@1f9d,1100 { memory-region = <&metis_cma>; };
};
```

**When to flip the switch**:

```bash
# Sustained 4K@30 + Metis @ ≥80% utilization for >5 min
watch -n1 'grep -E "Cma(Total|Free)" /proc/meminfo'
# If CmaFree drops to <100 MB under sustained load → fragmentation,
# enable per-device pools.
```

Until you observe that, the global pool is simpler and equally fast.

## 8. Post-flash power + thermal validation

`05_post_flash_validate.sh` now confirms:

- `nvpmodel -q` reports the configured mode active.
- No `/sys/class/thermal/cooling_device*/cur_state > 0` at idle (would
  mean we're already throttling before any inference load).

If either fails, the operator gets a loud `[FAIL]` before the flash is
declared mission-ready.

## 9. Summary of audit gates that now coexist

| Gate | What it checks | Where |
|---|---|---|
| Pre-flash audit | RT kernel, PCIe retries, CMA, DTBO, vermagic | `make audit` |
| Build-tree vermagic | All `.ko` produced by Phase 2 share one vermagic | end of Phase 2 |
| Rootfs vermagic | All `.ko` in `$ROOTFS/lib/modules/` share vermagic | `pre_flash_audit.sh` |
| Doctor preflight | Tarballs, vendor trees, host packages, board target | `make doctor` |
| Post-flash gauntlet | RT kernel active, isolated cores, CMA, MAXN, thermal, vermagic of every loaded `.ko`, mission-critical drivers loaded | `make verify` |
| Black-box AER | Live PCIe error counters → forensic trail | `jetson-av-pcie-aer-monitor.service` |
| Brownout guard | Metis on PCIe + power cap | `jetson-av-brownout-guard.service` |
| BTRFS scrub | NVMe bit-rot detection | `jetson-av-btrfs-scrub.timer` |

## 10. The "no concerns" checklist

After running `make ignite`, the device passes if:

```bash
ssh j@av-XX 'sudo /home/j/verify_tuning.sh'   # exit 0 == green gauntlet
ssh j@av-XX 'systemctl --no-pager --type=service \
              list-unit-files "jetson-av-*.service"'   # all enabled
ssh j@av-XX 'cat /run/jetson-av-link-state'   # "ok"
ssh j@av-XX 'btrfs scrub status /var/log/jetson-av/data | head'
ssh j@av-XX 'jetson-av-version'   # build matches what you flashed
```

Every one of these maps back to a fine-tuning lever documented above.
If any is red, follow the pointer in the script's output to the relevant
`/etc/jetson-av/*.conf` knob.
