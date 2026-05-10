---
title: Home
layout: default
nav_order: 1
description: "Custom PREEMPT_RT L4T R36.5 firmware image for Jetson Orin NX 16GB — Axelera Metis M.2 AI accelerator, Stereolabs ZED X stereo camera, Isaac ROS SLAM + inference, NVMe boot, fleet manufacturing pipeline."
permalink: /
---

# jetson-rt-stack
{: .fs-9 }

Jetson PREEMPT_RT firmware stack — Metis + ZED X + Isaac ROS
{: .fs-4 .fw-300 .text-grey-dk-000 }

Custom **PREEMPT_RT** L4T R36.5 image for the **Jetson Orin NX 16GB** — two independent layers. Stop at Layer 1 if all you need is Metis inference on NVMe with Wi-Fi. Add Layer 2 for the full RT vision stack: ZED X → cuVSLAM → nvblox → Nav2.
{: .fs-5 .fw-300 }

[Quickstart]({{ '/QUICKSTART' | relative_url }}){: .btn .btn-primary .fs-5 .mb-4 .mb-md-0 .mr-2 }
[Full tutorial]({{ '/COMMUNITY_POST' | relative_url }}){: .btn .fs-5 .mb-4 .mb-md-0 .mr-2 }
[GitHub](https://github.com/silicondoritos/jetson-rt-stack){: .btn .fs-5 .mb-4 .mb-md-0 }

---

## Layer 1 — Baseline: Jetson + Metis + NVMe + Wi-Fi (Phases 1–4)

Layer 1 is complete on its own. No camera or ROS required.

- **PREEMPT_RT kernel** — `NO_HZ_FULL`, CPU isolation cores 1–5, threaded IRQs, RCU NOCB offload. p99 max < 100 µs on isolated cores — see [RT tuning]({{ '/RT_KERNEL_OPTIMIZATION' | relative_url }}) for full test conditions.
- **Axelera Metis M.2 in-tree driver** — PCIe patience patch, udev rules, Voyager SDK 1.6 pip wheels in `/opt/av-env`. Vermagic guaranteed by in-tree build.
- **NVMe boot** from M.2 Key M slot via `flash_l4t_t234_nvme.xml`.
- **Realtek RTL8822CE** — M.2 Key E Wi-Fi/BT, in-tree `rtw88` driver.
- **Per-boot RT tuning** — `jetson-rt-tune.service`: MAXN clocks locked, IRQs pinned, performance governor.
- **Vermagic discipline** — in-tree build + `linux-headers-*.deb` prevents DKMS module mismatches.

`make verify` passing = Layer 1 complete. The Jetson is ready for Metis inference.

## Layer 2 — RT RT Vision Extension (Phases 5–7, all optional)

Install any or all of these on top of Layer 1. Each phase is independently opt-in.

- **ZED X stereo camera** — in-tree `sl_zedx.ko` (MAX9296 deserializer enforced, MAX96712 disabled to prevent silent frame corruption); ZED SDK 5.3. Requires ZED X driver source from Stereolabs.
- **DMABUF zero-copy pipeline** — ZED X → Tegra ISP → CMA → Metis NPU via dma_buf FD hand-off; no CPU memcpy on the hot path. See [DMABUF zero-copy]({{ '/DMABUF_ZEROCOPY' | relative_url }}) for the kernel bridge, ftrace setup, and verification script.
- **OpenCV 4.10.0 with CUDA** — built from source against CUDA 12.6, cuDNN 9.3, `CUDA_ARCH_BIN=8.7` (sm_87 / Orin Ampere). ~50 min first build; cached `.deb` for units 2–N. Verify `dpkg -l | grep libcudnn` shows `libcudnn9-cuda-12` post-flash. `apt python3-opencv` ships without CUDA/cuDNN/GStreamer.
- **ROS 2 Humble + Isaac ROS + Nav2** — cuVSLAM visual SLAM, nvblox 3D occupancy, Hybrid A* + DWB planning, CPU-pinned to isolated cores.
- **Platform hardening** — systemd watchdog, persistent journald, chrony, SSH/UFW hardening, Metis brownout guard, PCIe AER monitor, per-flight black-box recorder.
- **Fleet manufacturing** — build once, flash N units with unique identities. Golden-image clone for redeployment.

## Hardware

### Layer 1 — baseline (required)

| Component | Part |
|---|---|
| Module | Jetson Orin NX 16GB (P3767-0000) |
| Carrier | Any Orin NX 16GB carrier — P3509-class or equivalent; set `TARGET_BOARD` in `versions.env` |
| Board target | `jetson-orin-nano-devkit` — this is correct for Orin NX 16GB; see note below |
| AI accelerator | Axelera Metis M.2 (PCIe Gen3 x4, [`1f9d:1100`](https://community.axelera.ai/metis-pcie-7/axelera-metis-pcie-ai-accelerator-not-recognized-by-lspci-145)) |
| Storage | NVMe SSD, M.2 Key M (SoC supports PCIe Gen4 x4; carrier lane routing unverified) |
| Wi-Fi/BT | Realtek RTL8822CE, M.2 Key E |
| Recovery USB | [`0955:7323`](https://docs.nvidia.com/jetson/archives/r36.5/DeveloperGuide/SD/FlashingSupport.html) NVIDIA APX (`lsusb \| grep 0955:7323`) |

Other Orin NX 16GB carriers work — set `TARGET_BOARD` in `versions.env`.

### Layer 2 — RT vision extension (optional)

| Component | Part | Phase |
|---|---|---|
| Camera | Stereolabs ZED X via ZED Link Mono (MAX9296 GMSL2) | 5 |

{: .note }
**Why does an Orin NX 16GB use `jetson-orin-nano-devkit`?**

`jetson-orin-nano-devkit` is the flash config for the **P3509 carrier board**, not for a specific module. The P3509 carrier supports all P3767 modules — Orin NX 16GB (P3767-0000), Orin NX 8GB (P3767-0001), Orin Nano 8GB (P3767-0003/-0005), and Orin Nano 4GB (P3767-0004). NVIDIA named the developer kit platform "Orin Nano Devkit" after the carrier, not the module. Any P3509-class carrier uses this config.

**`-super` flash config vs. MAXN_SUPER nvpmodel — two different things:**

`jetson-orin-nano-devkit-super.conf` (added in JetPack 6.2) bundles the Super Mode nvpmodel table at flash time. On any P3509-class or P3768-derived carrier, use `jetson-orin-nano-devkit`. Super Mode is then enabled at runtime via `nvpmodel -m <index>` after confirming the carrier's HV rail can sustain 40 W.

The Orin NX 16GB MAXN_SUPER profile (40 W / 157 TOPS) is available in JetPack 6.2+. Default `power.conf` ships `NVPMODEL_MODE=4` (MAXN_SUPER, 40 W). Confirm the index with `nvpmodel --available` — it can vary. To reduce power: set `NVPMODEL_MODE=0` (MAXN, 25 W). HV rail validation: [Field Confirm Results]({{ '/FIELD_CONFIRM_RESULTS' | relative_url }}) §3.6.

## Quick start

```bash
git clone https://github.com/silicondoritos/jetson-rt-stack.git
cd jetson-rt-stack

# stage L4T tarballs and vendor trees next to the repo (see QUICKSTART + DRIVERS)

pip install kconfiglib       # one-time host dep for make menuconfig
make defconfig               # apply committed defaults (or: make menuconfig to customize)

make doctor          # preflight; fix any red
make docker-build    # one-time (~10 min)
make all             # extract → build → bake (~60–90 min)
make audit           # refuses to proceed if anything red

# put Jetson in APX recovery mode (short REC+GND, plug USB-C)
make flash           # ~20 min; auto-detects USB ID 0955:7323

# remove recovery jumper, power-cycle; first-boot service ~3–5 min

make verify          # post-flash checks over SSH
```

~90 min from a clean Ubuntu 22.04 host to a flashed, validated Jetson.

## Docs

### Start here

- [Quickstart]({{ '/QUICKSTART' | relative_url }}) — zero to flashed Jetson in 90 minutes
- [Full tutorial]({{ '/COMMUNITY_POST' | relative_url }}) — every command, every failure mode, every hardware gotcha
- [Runbook]({{ '/RUNBOOK' | relative_url }}) — decision trees for repeat deploys and recovery
- [Troubleshooting]({{ '/TROUBLESHOOTING' | relative_url }}) — symptom-first failure catalog
- [Verification report]({{ '/VERIFICATION_REPORT' | relative_url }}) — every magic value traced to vendor source (May 2026)

### Architecture

- [Configuration]({{ '/CONFIGURATION' | relative_url }}) — `make menuconfig`, plugin system, named profiles
- [Build]({{ '/BUILD' | relative_url }}) — phases 1–2, reproducibility
- [Flash]({{ '/FLASH' | relative_url }}) — phase 4, recovery mode
- [Automation]({{ '/AUTOMATION' | relative_url }}) — Makefile + scripts + `versions.env`
- [Kernel patches]({{ '/KERNEL_PATCHES' | relative_url }}) — every patch, in-tree integration
- [Kernel options]({{ '/KERNEL_OPTIMIZATIONS' | relative_url }}) — every `CONFIG_*` flag and rationale
- [RT tuning]({{ '/RT_KERNEL_OPTIMIZATION' | relative_url }}) — PREEMPT_RT, cyclictest, CPU isolation
- [DMABUF zero-copy]({{ '/DMABUF_ZEROCOPY' | relative_url }}) — ZED X → ISP → CMA → Metis: kernel bridge, tracepoints, verification
- [Vermagic]({{ '/VERMAGIC_STRATEGY' | relative_url }}) — why it breaks everything and how this build prevents it
- [Drivers]({{ '/DRIVERS' | relative_url }}) — ZED X, ZED SDK, Metis, Voyager SDK
- [Fine-tuning]({{ '/FINE_TUNING' | relative_url }}) — cross-component coordination

### Operations (Phase 7)

- [Platform resilience]({{ '/UAV_RESILIENCE' | relative_url }}) — watchdog, journald, kdump, security, chrony, brownout guard, PCIe AER
- [Black-box]({{ '/BLACKBOX' | relative_url }}) — hash-chained event log + NVENC ROS bag
- [Data partition]({{ '/DATA_PARTITION' | relative_url }}) — btrfs, zstd, scrub

### Application stack (Phase 5)

- [AV stack]({{ '/AV_STACK' | relative_url }}) — ROS 2 + Isaac ROS + cuVSLAM + nvblox + Nav2
- [CUDA libraries]({{ '/CUDA_LIBS' | relative_url }}) — OpenCV-CUDA, OpenGL/EGL/GLES, TensorRT, VPI

### Production

- [Fleet manufacturing]({{ '/FLEET' | relative_url }}) — phase 6: release tarballs, batch flash, audit trail
- [Golden image]({{ '/GOLDEN_IMAGE' | relative_url }}) — capture and redeploy a customized Jetson
- [NVIDIA references]({{ '/NVIDIA_REFERENCES' | relative_url }}) — annotated vendor bibliography
- [Verification framework]({{ '/VERIFICATION' | relative_url }}) — `step::run` pre/post-gates

### Posts

- [Community post]({{ '/COMMUNITY_POST' | relative_url }}) — long-form Axelera community tutorial
---

## License

[Apache 2.0](https://github.com/silicondoritos/jetson-rt-stack/blob/main/LICENSE).

## Acknowledgments

- Axelera team — bring-up guide and `axl-jetson.patch`
- NVIDIA Jetson Linux team — L4T R36.5 + public sources
- Stereolabs — ZED X / ZED Link Mono platform
- Linux kernel + PREEMPT_RT communities
