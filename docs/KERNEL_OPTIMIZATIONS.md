---
title: Kernel Options
layout: default
description: "Every CONFIG_* kernel flag in this build and the rationale behind each choice for PREEMPT_RT, DMABUF, CMA, and hardening."
nav_order: 14
---

# Kernel Optimizations

Every `CONFIG_*` flag beyond the NVIDIA stock defconfig. All appended to `arch/arm64/configs/defconfig` by `scripts/01_extract_and_patch.sh`.

The defconfig block is split into **eleven domains**. Each domain has a
purpose, a justification, and the specific cost/benefit on this hardware.

## 1. Real-Time Core (foundational)

```
CONFIG_PREEMPT_RT=y
CONFIG_NO_HZ_FULL=y
CONFIG_HZ_1000=y
CONFIG_CPU_ISOLATION=y
CONFIG_RCU_NOCB_CPU=y
CONFIG_IRQ_FORCED_THREADING=y
CONFIG_CPU_FREQ_DEFAULT_GOV_PERFORMANCE=y
# CONFIG_CPU_FREQ_GOV_ONDEMAND is not set
# CONFIG_CPU_FREQ_GOV_CONSERVATIVE is not set
```

- **PREEMPT_RT**: makes spinlocks sleepable, threads IRQ handlers.
  Required for sub-50µs jitter on cores 1–5.
- **NO_HZ_FULL**: tickless mode on isolated cores; the timer interrupt
  doesn't fire on cores 1–5.
- **HZ_1000**: 1ms timer base.
- **CPU_ISOLATION**: kernel-level enforcement that the scheduler skips
  isolated cores.
- **RCU_NOCB_CPU**: RCU callback offload — keeps RCU GC noise off RT cores.
- **IRQ_FORCED_THREADING**: every interrupt becomes a kernel thread we can
  prioritise/pin.

## 2. ZED X Deserializer

```
CONFIG_SL_DESER_MAX9296=m
# CONFIG_SL_DESER_MAX96712 is not set
```

ZED Link Mono uses the MAX9296 chip. Selecting MAX96712 produces
silently-corrupted frames. Documented in `docs/DRIVERS.md` §1.

## 3. DMABUF Zero-Copy Pipeline

```
CONFIG_SYNC_FILE=y
CONFIG_SW_SYNC=y
CONFIG_DMABUF_HEAPS=y
CONFIG_DMABUF_SYSFS_STATS=y
CONFIG_DMABUF_HEAPS_SYSTEM=y
CONFIG_DMABUF_HEAPS_CMA=y
CONFIG_CMA_SIZE_MBYTES=2048
```

The end-to-end byte path ZED X → ISP → Metis NPU is DMA-only.
`/dev/dma_heap/linux,cma` is the user-facing handle. **2 GB CMA** is
critical — stock JetPack reserves only 32 MB, which cannot fit two 4K
stereo frame buffers plus working space.

## 4. ARMv8.5-A Silicon Features

```
CONFIG_ARM64_PTR_AUTH=y
CONFIG_ARM64_BTI=y
CONFIG_ARM64_BTI_KERNEL=y
CONFIG_CRYPTO_AES_ARM64_CE=y
CONFIG_CRYPTO_SHA512_ARM64=y
CONFIG_KERNEL_MODE_NEON=y
```

Enables Pointer Authentication, Branch Target Identification, and
hardware-accelerated AES/SHA. Free hardening on Cortex-A78AE.

## 5. Aerospace Hardening & Resiliency

```
CONFIG_EDAC=y
CONFIG_EDAC_TEGRA=y
CONFIG_PSTORE=y
CONFIG_PSTORE_RAM=y
CONFIG_SOFT_WATCHDOG=y
CONFIG_HARDLOCKUP_DETECTOR=y
```

ECC reporting, persistent crash logs across reboot, watchdog. Essential
for aerial deployment where you can't power-cycle to debug.

## 6. RT Depth

```
CONFIG_HIGH_RES_TIMERS=y
CONFIG_HZ=1000
CONFIG_RCU_BOOST=y
CONFIG_RCU_BOOST_DELAY=500
# CONFIG_PREEMPT_DYNAMIC is not set
# CONFIG_NO_HZ_IDLE is not set
# CONFIG_NUMA_BALANCING is not set
# CONFIG_SCHED_AUTOGROUP is not set
# CONFIG_LATENCYTOP is not set
```

- **RCU_BOOST**: priority-inherits RCU readers when a higher-prio writer
  is starving. Without this, a low-prio task holding RCU can be preempted
  forever, causing >10 ms latency stalls.
- **PREEMPT_DYNAMIC off**: forces fixed PREEMPT_RT (no runtime switching).
- **NUMA_BALANCING off**: Orin NX is single-NUMA; balancing wastes cycles.
- **SCHED_AUTOGROUP off**: interferes with explicit cpuset/pin policies.
- **LATENCYTOP off**: per-task tracking adds measurable overhead.

## 7. Memory & Cache

```
CONFIG_TRANSPARENT_HUGEPAGE=y
CONFIG_TRANSPARENT_HUGEPAGE_MADVISE=y
CONFIG_HUGETLB_PAGE=y
CONFIG_USERFAULTFD=y
CONFIG_PAGE_REPORTING=y
# CONFIG_ZSWAP is not set
# CONFIG_ZRAM is not set
```

- **THP_MADVISE**: opt-in via `madvise()` so DDS/Voyager can ask for huge
  pages without forcing them on the whole system.
- **USERFAULTFD**: needed for advanced UVM / live migration patterns.
- **ZSWAP/ZRAM off**: compression in the swap path is not acceptable for RT.

## 8. cgroups v2

```
CONFIG_CGROUPS=y
CONFIG_CGROUP_SCHED=y
CONFIG_CGROUP_CPUACCT=y
CONFIG_CPUSETS=y
CONFIG_CGROUP_DEVICE=y
CONFIG_CGROUP_FREEZER=y
CONFIG_CGROUP_PIDS=y
CONFIG_CGROUP_BPF=y
CONFIG_MEMCG=y
CONFIG_MEMCG_SWAP=y
```

Required for `systemd-run --scope -p AllowedCPUs=4-5 ...` style pinning
that the AV stack uses for cuVSLAM (cores 4–5) and
Metis runtime (core 1).

## 9. Networking

```
CONFIG_NET_SCH_FQ=m
CONFIG_NET_SCH_FQ_CODEL=m
CONFIG_TCP_CONG_BBR=m
CONFIG_DEFAULT_TCP_CONG="bbr"
CONFIG_NET_FOU=m
CONFIG_BPF_JIT=y
CONFIG_BPF_JIT_ALWAYS_ON=y
CONFIG_XDP_SOCKETS=y
CONFIG_NET_RX_BUSY_POLL=y
```

- **FQ / FQ_CODEL**: fair-queue schedulers; `jetson_rt_tune.sh` switches
  the primary NIC to `fq` so DDS multicast doesn't starve.
- **BBR**: superior congestion control for telemetry tunneling.
- **BPF_JIT** + **XDP_SOCKETS**: zero-copy packet I/O for future use
  (e.g. AF_XDP-based LiDAR ingest).
- **RX_BUSY_POLL**: low-latency receive at the cost of CPU; rt_tune.sh
  governs which NIC uses it.

## 10. I/O

```
CONFIG_BLK_MQ_PCI=y
CONFIG_NVME_MULTIPATH=y
CONFIG_NVME_HWMON=y
CONFIG_IO_URING=y
CONFIG_USB_ANNOUNCE_NEW_DEVICES=y
CONFIG_USB_SERIAL_FTDI_SIO=m
CONFIG_USB_SERIAL_CP210X=m
```

- **NVME_HWMON**: temperature monitoring for thermal throttling decisions.
- **IO_URING**: async I/O for Isaac ROS bag recording.
- **CP210X / FTDI_SIO**: USB-serial bridges for peripheral connectivity.

## 11. Wi-Fi & Module Discipline

```
CONFIG_RTW88=m
CONFIG_RTW88_8822CE=m

CONFIG_MODVERSIONS=y
CONFIG_MODULE_SRCVERSION_ALL=y
# CONFIG_MODULE_FORCE_LOAD is not set
```

- **RTW88_8822CE**: Realtek M.2 Key E module driver.
- **MODVERSIONS** + **SRCVERSION_ALL**: stricter than vermagic — per-symbol
  CRC checks. See `docs/VERMAGIC_STRATEGY.md`.
- **MODULE_FORCE_LOAD off**: prevents the dangerous `insmod --force` escape.

## 12. Hardening (no RT cost)

```
CONFIG_HARDENED_USERCOPY=y
CONFIG_FORTIFY_SOURCE=y
CONFIG_STACKPROTECTOR_STRONG=y
CONFIG_RANDOMIZE_BASE=y
CONFIG_RANDOMIZE_MODULE_REGION_FULL=y
CONFIG_INIT_STACK_ALL_ZERO=y
# CONFIG_DEVMEM is not set
# CONFIG_DEVKMEM is not set
# CONFIG_LEGACY_PTYS is not set
```

KASLR, fortify-source, hardened user-copy, stack-zero. `/dev/mem` and
`/dev/kmem` are disabled — there's no legitimate use for them on a
sealed AV platform and they're a privilege-escalation primitive.

## 13. Driver In-Tree Promotions

```
CONFIG_AXELERA_METIS=m
CONFIG_VIDEO_ZEDX=m
CONFIG_VIDEO_ZEDX_AR0234=m
CONFIG_VIDEO_ZEDX_IMX678=m
```

These flip on the in-tree Kconfig stubs that `01_extract_and_patch.sh`
generates under `drivers/misc/axelera/` and `drivers/media/i2c/zedx/`.
See `docs/VERMAGIC_STRATEGY.md` for why this matters.

## 14. PCIe Power Management

```
# CONFIG_PCIEASPM is not set
```

Disables PCIe Active State Power Management at compile time. The Axelera
Metis cannot wake from L1 sleep without 10–50 µs latency, which matters
when inference happens every frame. We also force `pcie_aspm=off` in
`extlinux.conf` and `/sys/bus/pci/devices/*/power/control` to `on` in
`jetson_rt_tune.sh` — three-layer enforcement.

## 15. Debug Strip (no jitter sources)

```
# CONFIG_KASAN is not set
# CONFIG_PROVE_LOCKING is not set
# CONFIG_DEBUG_LOCKDEP is not set
# CONFIG_SLUB_DEBUG is not set
# CONFIG_KMEMLEAK is not set
# CONFIG_FUNCTION_GRAPH_TRACER is not set
# CONFIG_DYNAMIC_FTRACE is not set
# CONFIG_SCHED_DEBUG is not set
# CONFIG_FUNCTION_TRACER is not set
# CONFIG_DEBUG_PREEMPT is not set
# CONFIG_DEBUG_RT_MUTEXES is not set
# CONFIG_PROVE_RCU is not set
# CONFIG_TIMER_STATS is not set
# CONFIG_DEBUG_VM is not set
# CONFIG_DEBUG_BUGVERBOSE is not set
```

Each of these adds 1–10 µs of measurable jitter through tracing hooks,
locking instrumentation, or memory-allocation poisoning. None are worth
it on a deployed system; rebuild with them on only when chasing a bug.

## 16. Filesystem Extras

```
CONFIG_FUSE_FS=m
CONFIG_VFAT_FS=m
CONFIG_NTFS_FS=m
```

For mounting external SD/USB storage written by Windows-based ground
control. `FUSE_FS` covers any user-space FS plumbing.

---

## Verification

After Phase 2, the audit gate (`pre_flash_audit.sh`) checks the most
critical of these end-to-end. To audit a specific flag manually:

```bash
# Inspect the staged defconfig
grep CONFIG_RCU_BOOST \
    latest_jetson/Linux_for_Tegra/source/kernel/kernel-jammy-src/arch/arm64/configs/defconfig

# Inspect the built kernel's effective config (post-build)
zcat latest_jetson/Linux_for_Tegra/kernel/Image \
    | strings | grep -m1 "Linux version"
```

On the running Jetson:

```bash
zcat /proc/config.gz | grep CONFIG_PREEMPT_RT
zcat /proc/config.gz | grep CONFIG_CMA_SIZE_MBYTES
```

(`/proc/config.gz` is exposed because `CONFIG_IKCONFIG=y` and
`CONFIG_IKCONFIG_PROC=y`.)
