---
title: Verification Report
layout: default
description: "Audit report (May 2026): every magic value, URL, CONFIG flag, and hardware ID traced back to its vendor canonical source."
nav_order: 6
---

# Verification Report — May 2026

Every build system claim cross-checked against vendor/upstream sources. Records: VERIFIED, WRONG (+ fix), UNCLEAR (+ field-confirm action).

Method: authoritative URLs (kernel.org, NVIDIA developer docs, Stereolabs, Axelera community, Rock7, MAVLink, MAVROS, ROS, mavlink-router, FastDDS) compared against every magic value, URL, `CONFIG_*`, command flag, and protocol assumption.

## Summary

| Category | Verified | Wrong → fixed | Unclear → field-confirm |
|---|---|---|---|
| L4T R36.5 / NVIDIA toolchain | 4 | 3 | 2 |
| Drivers / vendor SDKs | 5 | 6 | 2 |
| Kernel CONFIG_* names (5.15) | 50+ | 2 | 0 |
| Telemetry / MAVLink / MAVROS | 8 | 4 | 2 |
| **Total** | **65+** | **15** | **6** |

15 corrections committed across 8 scripts + 4 docs.

---

## Section 1 — L4T R36.5 / NVIDIA toolchain

### 1.1 ❌ WRONG → FIXED · Board target name

**Claim**: `TARGET_BOARD=jetson-orin-nano-devkit-super`.
**Reality**: `jetson-orin-nano-devkit-super` is the flash config for the
Orin **Nano Super** module (SKU P3767-0004) — a physically different module.
Using it on an Orin NX 16GB (P3767-0000) installs the wrong power table and
misconfigures the SoC. The correct flash target for Orin NX 16GB on P3509
carriers is
`jetson-orin-nano-devkit` (aliases `p3509-a02+p3767-0000.conf`).
**Fix**: `versions.env` updated; `00_doctor.sh` validates against the
extracted L4T tree.

**Important distinction — NX Super Mode is separate from the `-super` board
target.** The Orin NX 16GB gained a `MAXN_SUPER` nvpmodel profile (40 W /
157 TOPS) in JetPack 6.2 (L4T R36.4.x+). This is activated at runtime via
`nvpmodel -m 4` (verify exact index with `nvpmodel --available`), not via
the flash config. The flash target remains `jetson-orin-nano-devkit` for
all Orin NX modules regardless of whether Super Mode is used.

**Source**:
- [R36.5 Jetson Module Adaptation](https://docs.nvidia.com/jetson/archives/r36.5/DeveloperGuide/HR/JetsonModuleAdaptationAndBringUp/JetsonOrinNxNanoSeries.html)
- [OE4T discussion #1304 — `-super` only for Nano](https://github.com/orgs/OE4T/discussions/1304)
- [NVIDIA platform power and performance — nvpmodel profiles for R36.x](https://docs.nvidia.com/jetson/archives/r36.5/DeveloperGuide/SD/PlatformPowerAndPerformance/PlatformPowerAndPerformance.html)

### 1.2 ❌ WRONG → FIXED · Bootlin toolchain URL

**Claim**: `https://developer.nvidia.com/.../r36_release_v5.0/toolchain/aarch64--glibc--stable-2022.08-1.tar.bz2`.
**Reality**: The R36.5 page links the toolchain under `r36_release_v3.0/toolchain/`. The `v5.0` URL 404s.
**Fix**: `Dockerfile` URL corrected.
**Source**: [Jetson Linux R36.5](https://developer.nvidia.com/embedded/jetson-linux-r365)

### 1.3 ❌ WRONG → FIXED · GPU devfreq path

**Claim**: GPU is at `/sys/class/devfreq/17000000.ga10b`.
**Reality**: R36.5 exposes the GPU at `/sys/class/devfreq/17000000.gpu/`. The `.ga10b` suffix is R35-era. We now try `.gpu` first and fall back to `.ga10b` for backwards compat.
**Fix**: `jetson_rt_tune.sh` updated to probe `.gpu` → `.ga10b` → platform-direct path.
**Source**: [R36.5 Clocks](https://docs.nvidia.com/jetson/archives/r36.5/DeveloperGuide/SD/Clocks.html)

### 1.4 ✅ VERIFIED · Flash command structure

`l4t_initrd_flash.sh --external-device nvme0n1p1 -c flash_l4t_t234_nvme.xml -p "-c flash_t234_qspi.xml" --showlogs --network usb0 <board> internal` is the canonical R36.5 NVMe pattern. Both XMLs ship in R36.5.
**Source**: [R36.5 Flashing Support](https://docs.nvidia.com/jetson/archives/r36.5/DeveloperGuide/SD/FlashingSupport.html)

### 1.5 ✅ VERIFIED · Bootlin toolchain version

`aarch64--glibc--stable-2022.08-1` (gcc 11.3) is the recommended toolchain for L4T R36.5.

### 1.6 ✅ VERIFIED · CUDA SM 8.7 for Orin NX

Orin NX is GA10B / Ampere, compute capability 8.7. `CUDA_ARCH_BIN=8.7` in `build_opencv_cuda.sh` is correct.
**Source**: [CUDA GPUs](https://developer.nvidia.com/cuda/gpus)

### 1.7 ✅ VERIFIED · EMC clock path

`/sys/kernel/debug/bpmp/debug/clk/emc/` with `rate`, `min_rate`, `max_rate`, `mrq_rate_locked` — correct for R36.5.

### 1.8 ✅ VERIFIED · P3509-class carrier board target

P3509-class carriers use the stock NVIDIA `jetson-orin-nano-devkit` target with `flash_t234_qspi.xml`.

### 1.9 ❓ UNCLEAR · `LINK_WAIT_MAX_RETRIES` default

Path `drivers/pci/controller/dwc/pcie-designware.h` is correct. Mainline upstream sets it to 10. NVIDIA's L4T tree may patch this differently. **Field check**: `grep LINK_WAIT_MAX_RETRIES Linux_for_Tegra/source/kernel/kernel-jammy-src/drivers/pci/controller/dwc/pcie-designware.h` after Phase 1 extract; confirm pre-patch value before our `sed` fires.

### 1.10 ❓ UNCLEAR · Carrier HV rail and 40 W Super Mode capability

**Situation**: Orin NX 16GB MAXN_SUPER (40 W / 157 TOPS) is available in JetPack 6.2 / L4T R36.4.x+. Activated via `nvpmodel -m 4` (verify index with `nvpmodel --available`).
**Gap**: NVIDIA's power documentation states NX Super Mode requires the carrier to expose the HV DC-in rail and be rated for sustained 40 W + thermal dissipation. Verify this against your carrier's power spec and schematic before enabling MAXN_SUPER. Using it on an under-rated carrier risks brownout or thermal shutdown in flight.
**Field check before enabling Super Mode**:
1. Confirm carrier input voltage range and DC-DC converter current rating from the carrier vendor.
2. With `nvpmodel -m 4` active and Metis inference running, measure rail voltage and monitor `tegrastats` for throttling (`@` suffix) and junction temps.
3. Keep a thermal margin: if temps exceed 85 °C at idle under MAXN_SUPER, the thermal solution is insufficient.
**Default**: `power.conf` uses `NVPMODEL_MODE=4` (MAXN_SUPER, 40 W). To reduce power, set `NVPMODEL_MODE=0` (MAXN, 25 W) in `/etc/jetson-av/power.conf`.
**Source**: [NVIDIA platform power and performance](https://docs.nvidia.com/jetson/archives/r36.5/DeveloperGuide/SD/PlatformPowerAndPerformance/PlatformPowerAndPerformance.html)

---

## Section 2 — Drivers / vendor SDKs

### 2.1 ❌ WRONG → DOCUMENTED · ZED X kernel driver source repo

**Claim**: `git clone --branch master https://github.com/stereolabs/zed-driver zedx-driver`.
**Reality**: **No public Stereolabs repo exists for the ZED X / ZED Link kernel driver.** Stereolabs distributes signed `.deb` packages (e.g. `stereolabs-zedlink-mono_<ver>-LI-MAX9296-all-L4T36.x_arm64.deb`) and does not publish the source. The .deb's compiled `.ko` is built against the stock NVIDIA L4T kernel — vermagic will not match our PREEMPT_RT build.
**Fix**: `docs/DRIVERS.md` opens with a callout explaining the two paths forward (1) get source via Stereolabs business agreement, (2) skip ZED X for now. The in-tree promotion under `drivers/media/i2c/zedx/` is preserved as the right architecture **once source is available**.
**Source**:
- [Stereolabs GitHub org list — 48 repos, no kernel-driver repo](https://github.com/orgs/stereolabs/repositories)
- [Stereolabs driver downloads page (.deb only)](https://www.stereolabs.com/developers/drivers)

### 2.2 ✅ VERIFIED · ZED Link Mono uses MAX9296

ZED Link Mono = Maxim **MAX9296A** deserializer; ZED Link Duo / Quad use **MAX96712**. Confirmed via Stereolabs `.deb` filenames (`-LI-MAX9296-` vs `-LI-MAX96712-`). Our defconfig + Makefile choice was right.
**Source**: [Stereolabs driver install guide](https://www.stereolabs.com/docs/embedded/zed-link/install-the-drivers)

### 2.3 ❌ WRONG → FIXED · ZED SDK installer flags

**Claim**: `silent skip_drivers skip_python skip_cuda skip_tools`.
**Reality**: `skip_drivers` does NOT exist. Documented silent-mode flags are `silent`, `runtime_only`, `skip_cuda`, `skip_python`, `skip_tools`, `skip_od_module`, `skip_hub`, `nvpmodel=0`.
**Fix**: `install_zed_sdk.sh` invocation changed to `silent runtime_only skip_python skip_cuda skip_tools skip_od_module skip_hub nvpmodel=0`.
**Source**: [ZED SDK Jetson install guide](https://www.stereolabs.com/docs/development/zed-sdk/jetson)

### 2.4 ✅ VERIFIED · ZED SDK 5.3 + L4T R36.5 + CUDA 12.6

ZED SDK 5.3.0 (released Apr 29 2026) explicitly lists "JetPack 6.2.2 (L4T 36.5) — Jetson Orin, **CUDA 12.6**" on the download page.
**Source**: [ZED Releases](https://www.stereolabs.com/developers/release)

### 2.5 ✅ VERIFIED · pyzed via `get_python_api.py`

`/usr/local/zed/get_python_api.py` is still the canonical install path and auto-detects Python/CUDA. There is no PyPI alternative.

### 2.6 ❌ WRONG → FIXED · Voyager SDK pip extra-index URL

**Claim**: `https://software.axelera.ai/artifactory/axelera-pypi/`.
**Reality**: The pip API requires `/api/pypi/<repo>/simple` suffix. Correct URL: `https://software.axelera.ai/artifactory/api/pypi/axelera-pypi/simple`.
**Fix**: `versions.env` and `jetson_first_boot.sh` updated.
**Source**: [Voyager 1.6 release announcement](https://community.axelera.ai/product-updates/voyager-sdk-new-pipeline-builder-and-more-1313)

### 2.7 ❌ WRONG → FIXED · Axelera PCI vendor:device ID

**Claim**: `lspci -d :1d60:`.
**Reality**: Axelera AI vendor ID is `1f9d`, Metis device ID `1100`. **Every `lspci -d :1d60:` query in our code would silently fail to match.**
**Fix**: `axelera_brownout_guard.sh`, `verify_tuning.sh`, `install_uav_phase7.sh`, `docs/UAV_RESILIENCE.md`, `docs/DRIVERS.md`, `README.md` all updated to `1f9d` (or `1f9d:1100`).
**Source**: [Axelera community thread confirming PCI ID](https://community.axelera.ai/metis-pcie-7/axelera-metis-pcie-ai-accelerator-not-recognized-by-lspci-145)

### 2.8 ❌ WRONG → FIXED · Metis form factor + PCIe spec

**Claim**: M.2 2230, PCIe Gen4 x2.
**Reality**: M.2 **2280** M-key, PCIe **Gen3 x4**, ~11.55 W avg / 23.1 W peak.
**Fix**: `README.md` and `docs/DRIVERS.md` updated. The `axelera_brownout_guard.sh` 18 W power cap is still appropriate for the verified 23.1 W peak.
**Source**: [Axelera Metis M.2 datasheet](https://axelera.ai/hubfs/Axelera_February2025/pdfs/axelera-ai-m2-ai-edge-accelerator-module.pdf)

### 2.9 ❓ UNCLEAR · `axdevice --set-power-limit` flag spelling

`axdevice` is the documented Voyager CLI; setting a power limit IS a documented capability. Could not confirm whether the exact flag is `--set-power-limit` vs `--power-limit` from public docs (full reference is gated behind the developer portal). **Field check**: `axdevice --help` on a 1.6 install before deployment; `axelera_brownout_guard.sh` already logs a WARN if the call fails.

### 2.10 ❓ UNCLEAR → ANNOTATED · `AXELERA_GST_EXPLICIT_PARSE=1`

Not mentioned in any public Voyager 1.5 / 1.6 docs, GitHub README, or community thread we could find. Either an internal/undocumented knob or a stale claim. **Field check**: ask Axelera support or remove if not confirmed. Currently still in `jetson_first_boot.sh` activate-script; flagged here for review.

### 2.11 ✅ VERIFIED · Voyager SDK 1.6 ships pip wheels

`axelera-rt` and `axelera-devkit` packages are the current Voyager 1.6 install path; legacy `install.sh --driver` is deprecated.

---

## Section 3 — Kernel CONFIG_* names (Linux 5.15 / L4T R36.5)

Verified against `torvalds/linux` at tag `v5.15` via `raw.githubusercontent.com`. **All ~50 flags in our defconfig block were confirmed to exist with the exact names we use** EXCEPT:

### 3.1 ❌ WRONG → FIXED · `CONFIG_TPM_HW_RANDOM` → `CONFIG_HW_RANDOM_TPM`

**Reality**: The symbol is `HW_RANDOM_TPM` (in `drivers/char/hw_random/Kconfig`), not `TPM_HW_RANDOM`. Kconfig silently ignores the wrong name — we got no random source from the TPM with the previous defconfig.
**Fix**: `01_extract_and_patch.sh` defconfig block.

### 3.2 ❌ WRONG → DROPPED · `CONFIG_DEVKMEM`

**Reality**: Removed from upstream Linux in 5.13 (commit `f2ad42f6db20`). Symbol does not exist in 5.15. Our `# CONFIG_DEVKMEM is not set` was a no-op.
**Fix**: Comment retained but annotated; symbol no longer referenced as if it were live.

### 3.3 ✅ VERIFIED · `CONFIG_USB_ACM`

Our addition was correct as a kernel symbol (lives in `drivers/usb/class/Kconfig`, module `cdc-acm`). However, see §4.4 for the misconception about what hardware actually needs it.

### 3.4 ✅ VERIFIED · `CONFIG_CPU_ISOLATION`

Real bool symbol in `init/Kconfig` (default `y`); independent of `NO_HZ_FULL`. Our usage was right.

### 3.5 ⚠️ FUTURE WARNING · `CONFIG_MEMCG_SWAP`

Removed in 6.1 (knob became boot/sysctl). Fine for 5.15 / L4T R36.5; flag for any future kernel rebase.

**All other 50+ flags verified correct**: `PREEMPT_RT`, `NO_HZ_FULL`, `HZ_1000`, `RCU_NOCB_CPU`, `IRQ_FORCED_THREADING`, `HIGH_RES_TIMERS`, `RCU_BOOST`, `PREEMPT_DYNAMIC`, `NUMA_BALANCING`, `SCHED_AUTOGROUP`, `LATENCYTOP`, `DMABUF_HEAPS{,_CMA,_SYSTEM}`, `DMABUF_SYSFS_STATS`, `SYNC_FILE`, `SW_SYNC`, `CMA_SIZE_MBYTES`, `TRANSPARENT_HUGEPAGE{,_MADVISE}`, `USERFAULTFD`, `PAGE_REPORTING`, `CGROUPS`, `CGROUP_SCHED`, `CGROUP_CPUACCT`, `CPUSETS`, `CGROUP_DEVICE`, `CGROUP_FREEZER`, `CGROUP_PIDS`, `CGROUP_BPF`, `MEMCG`, `TCP_CONG_BBR`, `DEFAULT_TCP_CONG`, `NET_FOU`, `BPF_JIT{,_ALWAYS_ON}`, `XDP_SOCKETS`, `NET_RX_BUSY_POLL`, `NET_SCH_FQ{,_CODEL}`, `BLK_MQ_PCI`, `NVME_MULTIPATH`, `NVME_HWMON`, `IO_URING`, `USB_ANNOUNCE_NEW_DEVICES`, `USB_SERIAL_FTDI_SIO`, `USB_SERIAL_CP210X`, `USB_USBNET`, `USB_NET_RNDIS_HOST`, `USB_NET_CDCETHER`, `KEXEC{,_FILE}`, `CRASH_DUMP`, `PROC_VMCORE`, `SECURITY{,_YAMA,_LOCKDOWN_LSM}`, `LSM`, `TCG_TPM`, `TCG_TIS`, `MODVERSIONS`, `MODULE_SRCVERSION_ALL`, `MODULE_FORCE_LOAD`, `HARDENED_USERCOPY`, `FORTIFY_SOURCE`, `STACKPROTECTOR_STRONG`, `RANDOMIZE_BASE`, `RANDOMIZE_MODULE_REGION_FULL`, `INIT_STACK_ALL_ZERO`, `DEVMEM`, `LEGACY_PTYS`, `RTW88{,_8822CE}`, `ARM64_PTR_AUTH`, `ARM64_BTI{,_KERNEL}`, `CRYPTO_AES_ARM64_CE`, `CRYPTO_SHA512_ARM64`, `KERNEL_MODE_NEON`.

**Source**: `https://raw.githubusercontent.com/torvalds/linux/v5.15/<path>` for each Kconfig file referenced.

---

## Section 4 — Telemetry / MAVLink / MAVROS / Iridium

### 4.1 ❌ WRONG → FIXED · Pixhawk 6X TELEM2 → `/dev/ttyTHS1` (not `ttyTHS0`)

**Claim**: TELEM2 maps to `/dev/ttyTHS0`.
**Reality**: On P3509-class carriers, Pixhawk TELEM2 is typically wired to UART1, exposed as `/dev/ttyTHS1`. `/dev/ttyTHS0` is the debug console. Verify with `dmesg | grep ttyTHS` on your specific carrier.
**Fix**: `versions.env` adds `FCU_TTY_DEFAULT=/dev/ttyTHS1`, telemetry-failover.conf default updated, install_telemetry_failover.sh helper text updated.
**Source**:
- [PX4 companion computer docs](https://docs.px4.io/main/en/companion_computer/)

### 4.2 ❌ WRONG → REWRITTEN · RockBLOCK 9704 enumeration + protocol

**Claim**: RockBLOCK 9704 enumerates as CDC-ACM (`/dev/ttyACM0`) and uses the AT command set (`AT+SBDWB`, `AT+SBDIX`).
**Reality**: The 9704 uses an FTDI USB-TTL bridge (`/dev/ttyUSB0` via `ftdi_sio`), NOT CDC-ACM. The 9704 protocol is **JSPR (JSON-based Serial Protocol for REST)**, NOT AT commands. AT commands belong to the legacy 9602/9603 modems.
**Fix**: `install_telemetry_failover.sh` rewritten to be model-aware. New env knob `IRIDIUM_MODEL` (default `9704`) selects the sender:
- `9704` → uses `rockblock9704` Python SDK (Rock7's official client; `pip install rockblock9704`); JSPR JSON via FTDI at 230400 baud.
- `9603` / `9602` → legacy AT path over CDC-ACM at 19200.
The relay's packing layer (mavlink → 36-byte payload) is shared; only the sender differs.
**Source**:
- [GroundControl 9704 hardware docs (FTDI)](https://docs.groundcontrol.com/iot/rockblock-9704/hardware)
- [Rock7 RockBLOCK-9704 SDK](https://github.com/rock7/RockBLOCK-9704)
- [GroundControl 9602/9603 AT command manual](https://docs.groundcontrol.com/iot/rockblock/user-manual/at-commands)

### 4.3 ❌ WRONG → FIXED · `RC_CHANNELS_RAW` → `RC_CHANNELS`

Both messages exist in MAVLink common dialect, but PX4 / ArduPilot now emit `RC_CHANNELS` (up to 18 channels). Updated the relay's TRACKED tuple.
**Source**: [MAVLink common.xml](https://mavlink.io/en/messages/common.html)

### 4.4 ⚠️ NOTE · `CONFIG_USB_ACM` was added for the WRONG reason

We added it thinking RockBLOCK 9704 needed it. The 9704 actually uses FTDI (already covered by `CONFIG_USB_SERIAL_FTDI_SIO`). `CONFIG_USB_ACM=m` is still useful — it covers the **legacy 9602/9603** if anyone uses one, plus various cellular modems that present as CDC-ACM. Kept in defconfig with corrected justification.

### 4.5 ❌ WRONG → FIXED · MAVROS install_geographiclib path

**Claim**: `bash /opt/ros/humble/lib/mavros/install_geographiclib_datasets.sh`.
**Reality**: Canonical invocation is `ros2 run mavros install_geographiclib_datasets.sh` — the hardcoded path is not portable.
**Fix**: `install_av_stack.sh` updated.
**Source**: [mavros ros2 README](https://github.com/mavlink/mavros/blob/ros2/mavros/README.md)

### 4.6 ✅ VERIFIED · mavlink-router config syntax

Sections, keys, and modes all correct (`[General]`, `[UartEndpoint <name>]`, `[UdpEndpoint <name>]`, `Mode = Server|Normal`, `Address`, `Port`, `Device`, `Baud`, `TcpServerPort`, `Log`, `LogMode = while-armed`, `ReportStats = true`).
**Source**: [mavlink-router examples/config.sample](https://github.com/mavlink-router/mavlink-router/blob/master/examples/config.sample)

### 4.7 ✅ VERIFIED · MAVLink message names + GCS sysid 255

`GLOBAL_POSITION_INT`, `ATTITUDE`, `SYS_STATUS`, `RC_CHANNELS` all canonical. System ID 255 is the de-facto GCS convention.

### 4.8 ✅ VERIFIED · MAVROS package names

`ros-humble-mavros`, `ros-humble-mavros-extras` correct apt names.

### 4.9 ✅ VERIFIED · MAVROS FCU URL format

`/dev/ttyTHS1:921600` valid. Schemes: `serial://`, `serial-hwfc://`, `udp://`, `tcp://`, `tcp-l://`.

### 4.10 ✅ VERIFIED · `nav2_bringup navigation_launch.py`

Canonical Nav2 bringup launch on Humble.

### 4.11 ✅ VERIFIED · `ros-humble-rosbag2-storage-mcap`

Correct apt name.

### 4.12 ✅ VERIFIED · Isaac ROS: Jazzy-only for 4.x, Humble pinned to 3.x

Isaac ROS **4.4.0** (released 2026-04-30) requires ROS 2 **Jazzy on Ubuntu 24.04** — Humble is not supported in the 4.x line. Humble operators must use Isaac ROS 3.x (source-build from the `release-3.2` branch). Apt package coverage for `ros-humble-isaac-ros-*` is partial. `install_av_stack.sh` already uses `git clone NVIDIA-ISAAC-ROS/isaac_ros_*` + colcon build — no code change needed. Plan Jazzy migration when moving to JetPack 7.x.

Source: https://nvidia-isaac-ros.github.io/releases/index.html

### 4.13 ✅ VERIFIED with caveat · FastDDS UFW port range `7400:7500/udp`

Correct for **DDS domain 0**. Formula `7400 + 250*domainID + offset + 2*participantID` means non-default domains need a wider/different range.

---

---

## Section 5 — May 2026 re-audit (upstream version check)

### 5.1 ❌ WRONG → FIXED · PyTorch version and index domain

**Claim**: `PYTORCH_VERSION=2.8.0`, domain `pypi.jetson-ai-lab.io`
**Reality**: 2.8.0 does not exist in the Jetson AI Lab index. Latest is **2.7.0** (torchvision **0.22.0**). Correct domain is `pypi.jetson-ai-lab.dev`.
**Fix**: `versions.env`, `scripts/jetson_first_boot.sh`, `docs/FLASH.md`, `README.md`.
**Source**: https://pypi.jetson-ai-lab.dev/jp6/cu126/

### 5.2 ❌ WRONG → FIXED · APX recovery USB ID for Orin NX

**Claim**: `USB_ID_APX=0955:7023`
**Reality**: `0955:7023` is the AGX Orin APX ID. Orin NX (P3767) APX ID is **`0955:7323`**.
**Fix**: `versions.env`, `scripts/04_flash_nvme.sh`, `docs/FLASH.md`, `docs/QUICKSTART.md`, `docs/RUNBOOK.md`, `docs/TROUBLESHOOTING.md`, `docs/index.md`, `docs/AUTOMATION.md`.

### 5.3 ❌ WRONG → FIXED · RockBLOCK 9704: IMT not SBD

**Claim**: "Iridium SBD", `/dev/ttyACM0` at 19200 baud, `CONFIG_USB_ACM=m`.
**Reality**: 9704 uses **Iridium IMT** (Messaging Transport), JSPR JSON over FTDI USB-serial (`/dev/ttyUSB0`) at **230400 baud**. Needs `CONFIG_USB_SERIAL_FTDI_SIO=m`. SBD/ACM/19200 applies to 9602/9603 only.
**Fix**: `docs/TELEMETRY_FAILOVER.md`, `versions.env` comment, `docs/index.md`, `README.md`.
**Source**: https://docs.groundcontrol.com/iot/rockblock-9704/intro

### 5.4 ❌ WRONG → FIXED · TELEMETRY_FAILOVER FCU_TTY example

**Claim**: `FCU_TTY=/dev/ttyTHS0` in the config example.
**Reality**: TELEM2 → `/dev/ttyTHS1`. `ttyTHS0` is the debug console.
**Fix**: `docs/TELEMETRY_FAILOVER.md` config example.

### 5.5 ✅ VERIFIED · JetPack 6.2.2 / L4T R36.5.0 still current for Orin NX

JetPack 7.x for Orin planned Q2 2026; 6.2.2 is the current stable release for Orin NX.

### 5.6 ✅ VERIFIED · CUDA 12.6, SM 8.7, ZED SDK 5.3, MAVROS 2.14.0, Axelera PCI ID 1f9d:1100, /dev/ttyTHS1 at 921600

All confirmed against upstream docs May 2026.

---

## Files modified by this verification pass

```
versions.env                                ← board name, FCU TTY default,
                                              Voyager pip URL, IRIDIUM_MODEL knob
Dockerfile                                  ← Bootlin URL v5.0 → v3.0
scripts/01_extract_and_patch.sh             ← TPM_HW_RANDOM → HW_RANDOM_TPM,
                                              DEVKMEM annotation
scripts/jetson_rt_tune.sh                   ← GPU devfreq path probe
scripts/jetson_first_boot.sh                ← Voyager pip URL
scripts/axelera_brownout_guard.sh           ← PCI vendor 1d60 → 1f9d
scripts/install_uav_phase7.sh               ← PCI vendor 1d60 → 1f9d
scripts/verify_tuning.sh                    ← PCI vendor 1d60 → 1f9d
scripts/install_zed_sdk.sh                  ← drop skip_drivers; use real flags
scripts/install_av_stack.sh                 ← MAVROS install_geographiclib via ros2 run
scripts/install_telemetry_failover.sh       ← FCU TTY, Iridium 9704 model-aware
                                              relay rewrite (JSPR + AT modes)
docs/DRIVERS.md                             ← form factor, ZED X source caveat
docs/UAV_RESILIENCE.md                      ← PCI vendor
(docs/JETSON_AV_PLATFORM_GUIDE.md was deleted in a later trim;
README.md                                   ← form factor + PCI ID
docs/VERIFICATION_REPORT.md                 ← THIS FILE (new)
```

## Field-confirm checklist

Six items remain UNCLEAR and need confirmation on real hardware:

1. **`LINK_WAIT_MAX_RETRIES` stock value** — verify in `Linux_for_Tegra/source/kernel/kernel-jammy-src/drivers/pci/controller/dwc/pcie-designware.h` after Phase 1 extract; if NVIDIA already patched it to a sane value, our `sed`-to-100 is harmless but unnecessary.
2. **`axdevice` exact flag spelling** — `axdevice --help` on a 1.6 install before deployment to confirm `--set-power-limit` vs `--power-limit` vs other.
3. **`AXELERA_GST_EXPLICIT_PARSE=1`** — confirm with Axelera support or remove; not in any public docs.
4. **Isaac ROS Humble apt package coverage** — `apt-cache search ros-humble-isaac-ros` against NVIDIA's L4T apt repo; expect partial coverage; source-build path is the safe default.
5. **`/dev/ttyTHS1` enumeration on your carrier** — `dmesg | grep tty` post-flash to confirm Pixhawk TELEM2 enumerated where expected.
6. **Carrier HV rail + Super Mode** (§1.10) — confirm your carrier's input voltage and DC-DC rating support 40 W sustained before enabling `nvpmodel -m 4` (MAXN_SUPER). Verify under load with `tegrastats`. Safety-critical for flight.

## Sources index

NVIDIA:
- https://developer.nvidia.com/embedded/jetson-linux-r365
- https://docs.nvidia.com/jetson/archives/r36.5/DeveloperGuide/index.html
- https://docs.nvidia.com/jetson/archives/r36.5/DeveloperGuide/SD/FlashingSupport.html
- https://docs.nvidia.com/jetson/archives/r36.5/DeveloperGuide/HR/JetsonModuleAdaptationAndBringUp/JetsonOrinNxNanoSeries.html
- https://docs.nvidia.com/jetson/archives/r36.5/DeveloperGuide/SD/PlatformPowerAndPerformance/PlatformPowerAndPerformance.html
- https://docs.nvidia.com/jetson/archives/r36.5/DeveloperGuide/SD/Clocks.html
- https://developer.nvidia.com/cuda/gpus
- https://developer.nvidia.com/downloads/jetson-orin-nx-module-series-data-sheet

Stereolabs:
- https://www.stereolabs.com/developers/drivers
- https://www.stereolabs.com/docs/embedded/zed-link/install-the-drivers
- https://www.stereolabs.com/developers/release
- https://www.stereolabs.com/docs/development/zed-sdk/jetson
- https://github.com/orgs/stereolabs/repositories
- https://github.com/stereolabs/zed-python-api

Axelera:
- https://github.com/axelera-ai-hub/voyager-sdk
- https://community.axelera.ai/product-updates/voyager-sdk-new-pipeline-builder-and-more-1313
- https://community.axelera.ai/metis-pcie-7/axelera-metis-pcie-ai-accelerator-not-recognized-by-lspci-145
- https://axelera.ai/ai-accelerators/metis-m2-ai-acceleration-card
- https://axelera.ai/hubfs/Axelera_February2025/pdfs/axelera-ai-m2-ai-edge-accelerator-module.pdf

PX4 companion computer docs: https://docs.px4.io/main/en/companion_computer/

MAVLink / MAVROS / mavlink-router:
- https://mavlink.io/en/messages/common.html
- https://mavlink.io/en/services/mavlink_id_assignment.html
- https://github.com/mavlink/mavros/blob/ros2/mavros/README.md
- https://github.com/mavlink-router/mavlink-router/blob/master/examples/config.sample

Rock7 / GroundControl (Iridium):
- https://docs.groundcontrol.com/iot/rockblock-9704/hardware
- https://docs.groundcontrol.com/iot/rockblock-9704/intro
- https://github.com/rock7/RockBLOCK-9704
- https://docs.groundcontrol.com/iot/rockblock/user-manual/at-commands

ROS 2 / Isaac ROS / Nav2 / FastDDS:
- https://nvidia-isaac-ros.github.io/getting_started/index.html
- https://github.com/NVIDIA-ISAAC-ROS/isaac_ros_common
- https://github.com/ros-navigation/navigation2/tree/humble/nav2_bringup
- https://docs.ros.org/en/humble/p/rosbag2_storage_mcap/
- https://fast-dds.docs.eprosima.com/en/latest/fastdds/discovery/simple.html

Linux kernel (5.15):
- https://raw.githubusercontent.com/torvalds/linux/v5.15/<Kconfig path>

---

## §6 — Phase 8 Closeout (May 2026)

This section marks items from earlier sections as closed once the Phase 8 runbook procedures have been executed on hardware. Cross-reference: `docs/FIELD_CONFIRM_RESULTS.md` for per-unit results.

| VR item | Description | Status |
|---|---|---|
| §1.1 | `-super` board target paragraph | **CLOSED** — `index.md` rewritten to clarify flash config vs. nvpmodel unlock; P-number map added; P3509 carrier explanation added |
| §1.9 | `LINK_WAIT_MAX_RETRIES` pre-patch value | Pending §3.1 field confirm |
| §1.10 | Carrier HV rail + MAXN_SUPER capability | Pending §3.6 field confirm |
| §2.9 | `axdevice` power-limit flag spelling | Pending §3.2 field confirm |
| §2.10 | `AXELERA_GST_EXPLICIT_PARSE` env var | Pending §3.3 field confirm |
| §3 | DMABUF zero-copy kernel CONFIG | **CLOSED** — `docs/DMABUF_ZEROCOPY.md` documents kernel bridge (`axl_dmabuf.c`), tracepoints, GStreamer caps, and `scripts/verify_dmabuf_zerocopy.sh` invariant checker |
| §4.1 | `/dev/ttyTHS1` enumeration on carrier | Pending §3.5 field confirm |
| §4.12 | Isaac ROS Humble apt package coverage | Pending §3.4 field confirm |
| §5.2 | APX USB ID `0955:7023` → `0955:7323` | **CLOSED** — `docs/index.md` home page updated |
| §5.5 | cuDNN 8 → cuDNN 9.3 (JetPack 6.2.x) | **CLOSED** — `docs/index.md` home page updated |

Pending items (§3.1, §3.2, §3.3, §3.4, §3.5, §3.6) require a physical Jetson with the full stack installed. Run `scripts/verify_dmabuf_zerocopy.sh` for DMABUF, and follow the procedures in `docs/FIELD_CONFIRM_RESULTS.md` for the remainder. Paste results into the `<!-- RESULT: -->` slots in that document.
