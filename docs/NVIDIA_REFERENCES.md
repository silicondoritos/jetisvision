---
title: NVIDIA References
layout: default
description: "Annotated bibliography of all NVIDIA, Axelera, Stereolabs, and community canonical sources used to derive magic values in this build."
nav_order: 40
---

# NVIDIA Reference Index

Upstream NVIDIA / vendor docs cited by the build, verified May 2026.
>
> The previous revision of this repo carried ~16 MB of scraped HTML
> (`docs/nvidia_comprehensive/`, `docs/nvidia_r36.5/`, `docs/refs/`,
> `docs/external/`) plus 8 MB of build/flash log artifacts. Those have
> been removed — they were reference material that's available online
> at the canonical URLs below, plus our own scripts/docs already
> capture the relevant numbers (every `CONFIG_*`, every patch, every
> RT tuning value is in `docs/KERNEL_OPTIMIZATIONS.md`,
> `docs/KERNEL_PATCHES.md`, `docs/RT_KERNEL_OPTIMIZATION.md`).

## L4T R36.5 / JetPack 6.2.2 — primary references

These are the canonical pages our build pipeline references:

| Page | URL |
|---|---|
| Jetson Linux R36.5 download hub (BSP, rootfs, toolchain, public sources) | https://developer.nvidia.com/embedded/jetson-linux-r365 |
| Release notes (PDF) | https://docs.nvidia.com/jetson/archives/r36.5/ReleaseNotes/Jetson_Linux_Release_Notes_r36.5.pdf |
| Jetson Linux Developer Guide R36.5 (top) | https://docs.nvidia.com/jetson/archives/r36.5/DeveloperGuide/index.html |
| Quick Start | https://docs.nvidia.com/jetson/archives/r36.5/DeveloperGuide/IN/QuickStart.html |
| Flashing Support (the canonical reference for `l4t_initrd_flash.sh` flags + XMLs) | https://docs.nvidia.com/jetson/archives/r36.5/DeveloperGuide/SD/FlashingSupport.html |
| Kernel Customization (Bring Your Own Kernel) | https://docs.nvidia.com/jetson/archives/r36.5/DeveloperGuide/SD/Kernel/KernelCustomization.html |
| Boot Architecture (Orin boot flow, partition layout) | https://docs.nvidia.com/jetson/archives/r36.5/DeveloperGuide/AR/BootArchitecture.html |
| Module Adaptation (Orin NX/Nano series — board target names) | https://docs.nvidia.com/jetson/archives/r36.5/DeveloperGuide/HR/JetsonModuleAdaptationAndBringUp/JetsonOrinNxNanoSeries.html |
| Clocks (devfreq paths, BPMP debug clk tree, EMC) | https://docs.nvidia.com/jetson/archives/r36.5/DeveloperGuide/SD/Clocks.html |
| Backup & Restore (golden image clone) | https://docs.nvidia.com/jetson/archives/r36.5/DeveloperGuide/SD/FlashingSupport/BackupAndRestore.html |
| DBT (Device-Tree-Based Tooling) | https://docs.nvidia.com/jetson/archives/r36.5/DeveloperGuide/SD/Kernel/DBT.html |
| Power Management & nvpmodel | https://docs.nvidia.com/jetson/archives/r36.5/DeveloperGuide/SD/PlatformPowerAndPerformance/PlatformPowerAndPerformance.html |
| Jetson Orin NX module datasheet | https://developer.nvidia.com/downloads/jetson-orin-nx-module-series-data-sheet |
| CUDA GPU compute capability table (Orin NX = sm_87) | https://developer.nvidia.com/cuda/gpus |

## What we use each one FOR

- **Quick Start + Flashing Support** — original source for our
  `04_flash_nvme.sh` command structure (`l4t_initrd_flash.sh
  --external-device --network usb0 …`).
- **Kernel Customization (BYOK)** — original source for the
  cross-compile pattern and `LOCALVERSION`. Verified the Bootlin
  toolchain URL we ship comes from this page.
- **Boot Architecture** — original source for the `MB1 → MB2 → CBoot
  → UEFI → Linux` chain documented in `docs/COMMUNITY_POST.md` Part 4.
- **Module Adaptation (Orin NX/Nano series)** — settled the
  `TARGET_BOARD` confusion: Orin NX 16GB on a P3509-class carrier uses
  `jetson-orin-nano-devkit` (aliasing `p3509-a02+p3767-0000.conf`).
  The `-super` variant is Orin Nano power-table only.
  See `docs/VERIFICATION_REPORT.md` §1.1.
- **Clocks** — settled the GPU devfreq path: R36.x exposes the GPU at
  `/sys/class/devfreq/17000000.gpu/`, not the R35-era `.ga10b`. See
  `jetson_rt_tune.sh`.
- **Backup & Restore** — the canonical workflow our golden-image
  clone (`scripts/clone_golden.sh` + `scripts/flash_golden.sh`) is
  built on. See `docs/GOLDEN_IMAGE.md`.
- **Module datasheet** — pin counts, power envelope, JetPack matrix.

## Vendor / community references

Stereolabs ZED X / ZED Link Mono / ZED SDK:
- Drivers (`.deb` downloads — kernel module included): https://www.stereolabs.com/developers/drivers
- ZED Link install guide: https://www.stereolabs.com/docs/embedded/zed-link/install-the-drivers
- ZED SDK release / download: https://www.stereolabs.com/developers/release
- ZED SDK Jetson install (silent flags): https://www.stereolabs.com/docs/development/zed-sdk/jetson
- Python API (`get_python_api.py`): https://www.stereolabs.com/docs/development/python/install
- Python API repo: https://github.com/stereolabs/zed-python-api
- Stereolabs GitHub org: https://github.com/orgs/stereolabs/repositories

Axelera Voyager SDK / Metis M.2:
- Voyager SDK GitHub: https://github.com/axelera-ai-hub/voyager-sdk
- Voyager 1.6 release announcement (pip wheels): https://community.axelera.ai/product-updates/voyager-sdk-new-pipeline-builder-and-more-1313
- Metis M.2 product page: https://axelera.ai/ai-accelerators/metis-m2-ai-acceleration-card
- Metis M.2 datasheet (PDF): https://axelera.ai/hubfs/Axelera_February2025/pdfs/axelera-ai-m2-ai-edge-accelerator-module.pdf
- Community thread that pinned the PCI vendor ID `1f9d:1100` (we had `1d60` wrong before):
  https://community.axelera.ai/metis-pcie-7/axelera-metis-pcie-ai-accelerator-not-recognized-by-lspci-145
- Bring up Metis on Jetson Orin (Axelera Help Center):
  https://support.axelera.ai (search "Bring up Metis M.2 Jetson Orin")


ROS 2 Humble / Isaac ROS / Nav2:
- Isaac ROS getting started: https://nvidia-isaac-ros.github.io/getting_started/index.html
- isaac_ros_common: https://github.com/NVIDIA-ISAAC-ROS/isaac_ros_common
- Nav2 (humble branch): https://github.com/ros-navigation/navigation2/tree/humble/nav2_bringup
- rosbag2 mcap storage: https://docs.ros.org/en/humble/p/rosbag2_storage_mcap/
- FastDDS discovery (default UDP port range 7400–7500/udp): https://fast-dds.docs.eprosima.com/en/latest/fastdds/discovery/simple.html

Linux kernel (5.15 — what L4T R36.5 ships):
- Tagged tree (Kconfig sources for every CONFIG_*): https://github.com/torvalds/linux/tree/v5.15
- kernel.org cgit (same tree): https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/tree/?h=linux-5.15.y
- PREEMPT_RT documentation: https://wiki.linuxfoundation.org/realtime/start

## How to re-fetch any of these offline

If you need offline copies (e.g., shipping a flash station to a
network-restricted lab), `wget` / `curl` against the URLs above. The
old `scripts/scrape_nvidia_*.py` crawlers were just doing this in
bulk — they've been removed because (a) the bulk output is stale the
moment NVIDIA updates a page, and (b) every scrape was 506+ files for
maybe 5 pages we actually use.

A focused alternative (~10 lines):

```bash
mkdir -p offline_refs
for url in \
    "https://docs.nvidia.com/jetson/archives/r36.5/DeveloperGuide/IN/QuickStart.html" \
    "https://docs.nvidia.com/jetson/archives/r36.5/DeveloperGuide/SD/FlashingSupport.html" \
    "https://docs.nvidia.com/jetson/archives/r36.5/DeveloperGuide/SD/Kernel/KernelCustomization.html" \
    "https://docs.nvidia.com/jetson/archives/r36.5/DeveloperGuide/SD/FlashingSupport/BackupAndRestore.html" \
    "https://docs.nvidia.com/jetson/archives/r36.5/DeveloperGuide/HR/JetsonModuleAdaptationAndBringUp/JetsonOrinNxNanoSeries.html" \
; do
    wget -q -P offline_refs --convert-links --adjust-extension "$url"
done
```

## Where to find the canonical defconfig

Our build process already mutates the L4T-stock defconfig at
`Linux_for_Tegra/source/kernel/kernel-jammy-src/arch/arm64/configs/defconfig`
(injected by `scripts/01_extract_and_patch.sh`). The previous repo
ALSO carried separate copies of `defconfig.txt` and
`tegra_defconfig.txt` under `docs/refs/` — those are now removed
because they were stale snapshots of the same file that lives in the
L4T tarball. To inspect the stock baseline before our patches:

```bash
make extract                            # extracts L4T tarball
less latest_jetson/Linux_for_Tegra/source/kernel/kernel-jammy-src/arch/arm64/configs/defconfig
```

For a diff against our patched version:

```bash
diff -u \
   <(cat Linux_for_Tegra/source/kernel/kernel-jammy-src/arch/arm64/configs/defconfig) \
   <(cat Linux_for_Tegra/source/kernel/kernel-jammy-src/arch/arm64/configs/defconfig.orig)
```

(Phase 1 doesn't currently keep a `.orig` — if you need that, add
`cp defconfig defconfig.orig` to the script before the `cat >>`.)
