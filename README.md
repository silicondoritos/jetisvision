# jetson-rt-stack — Custom RT Jetson Orin NX 16GB image with Metis + ZED X + Isaac ROS

> Jetson PREEMPT_RT firmware stack — Metis + ZED X + Isaac ROS

[![License: Apache 2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![L4T](https://img.shields.io/badge/L4T-R36.5.0-76B900.svg)](https://developer.nvidia.com/embedded/jetson-linux-r365)
[![JetPack](https://img.shields.io/badge/JetPack-6.2.2-76B900.svg)](https://developer.nvidia.com/embedded/jetpack)
[![Kernel](https://img.shields.io/badge/kernel-5.15--tegra-orange.svg)](docs/VERMAGIC_STRATEGY.md)
[![Pages](https://img.shields.io/badge/docs-silicondoritos.github.io-success.svg)](https://silicondoritos.github.io/jetson-rt-stack/)

📖 **Full documentation site**: [silicondoritos.github.io/jetson-rt-stack](https://silicondoritos.github.io/jetson-rt-stack/) — same content, with sidebar navigation, search, and code highlighting. The complete tutorial lives there.

---

A complete, audited, repeatable build pipeline for a custom **PREEMPT_RT** L4T
R36.5 image targeting the **Jetson Orin NX 16GB**. Two independent layers:

**Layer 1 — Baseline (Phases 1–4).** Everything needed to run Axelera Metis
inference on NVMe with RT isolation and Wi-Fi. No camera or flight controller
required. `make verify` passing = done.

- **Axelera Metis M.2** (PCIe Gen3 x4) — in-tree driver, Voyager SDK pip wheels
- **NVMe boot** — `flash_l4t_t234_nvme.xml`, btrfs data partition
- **Realtek RTL8822CE** Wi-Fi/BT — M.2 Key E, in-tree `rtw88`
- **PREEMPT_RT kernel** — CPU isolation 1–5, MAXN clocks locked per-boot

**Layer 2 — RT Vision Extension (Phases 5–7, all optional).** Adds camera,
flight controller, and operational hardening on top of the baseline:

- **Stereolabs ZED X** stereo camera via **ZED Link Mono** (MAX9296 GMSL2)
- **ROS 2 Humble + Isaac ROS + Nav2** — cuVSLAM visual SLAM, nvblox 3D occupancy, Hybrid A* planning
- Fleet manufacturing + golden-image clone workflow for N identical units

**Hardware**: Jetson Orin NX 16GB on any P3509-class carrier. Set `TARGET_BOARD`
in [`versions.env`](versions.env) if yours differs from `jetson-orin-nano-devkit`.
Do **not** use `jetson-orin-nano-devkit-super` — that suffix selects the Orin **Nano**
power-table and misconfigures the NX power profile (see
[`docs/VERIFICATION_REPORT.md`](docs/VERIFICATION_REPORT.md) §1.1).

**NX Super Mode (40 W / 157 TOPS)**: As of JetPack 6.2 (L4T R36.4.x+) NVIDIA added a
`MAXN_SUPER` nvpmodel profile to the Orin NX 16GB, raising the ceiling from
25 W / 100 TOPS to **40 W / 157 TOPS**. This build defaults to MAXN_SUPER (mode 4).
**Prerequisite**: verify your carrier exposes the HV power rail and is rated for 40 W
sustained before enabling it — see [`docs/VERIFICATION_REPORT.md`](docs/VERIFICATION_REPORT.md) §1.10.
MAXN_SUPER is absent on JetPack 6.0 and 6.1.

**Long-form guide**: [`docs/COMMUNITY_POST.md`](docs/COMMUNITY_POST.md) —
every command, every gotcha, every war story for getting this stack
into production. Built from the original Axelera community bring-up guide,
extended to a fleet-deployable, validated, RT-tuned image.

> **First time here?** Read [docs/QUICKSTART.md](docs/QUICKSTART.md) to go from a clean Ubuntu host to a flashed Jetson in 90 minutes.
> **Operating it?** [docs/RUNBOOK.md](docs/RUNBOOK.md) has decision trees for repeat deployments and recovery.
> **Want the full story?** [docs/COMMUNITY_POST.md](docs/COMMUNITY_POST.md) — the long-form guide.
> **Just want a list of commands?** `make help` (or `make list-targets` for everything).
> **Pin manifest?** `make versions` reads [`versions.env`](versions.env).

## Acknowledgments

- The Axelera team, especially the bring-up guide and `axl-jetson.patch`
  that started this work.
- NVIDIA Jetson Linux team for L4T R36.5 + the public sources.
- Stereolabs for the ZED X / ZED Link Mono platform.
- The Linux kernel + PREEMPT_RT communities.
- Everyone who contributed questions and issues that drove this work.

Licensed under the **Apache License, Version 2.0** — see
[`LICENSE`](LICENSE) and [`NOTICE`](NOTICE).

---

## 1. Hardware Topology (What We Know)

The Jetson Orin NX 16GB Devkit carrier board is the physical foundation. We have mapped the peripherals to their specific hardware interfaces:

| Peripheral | Interface | Purpose |
|------------|-----------|---------|
| **NVMe Boot SSD** | M.2 Key M (2280) | Primary OS storage (PCIe Gen4 x4 per SoC; actual BW depends on carrier lane routing) |
| **Axelera Metis M.2** | M.2 Key M (2280) | AI Inference Accelerator (PCIe Gen3 x4); PCI ID `1f9d:1100` |
| **Realtek Module** | M.2 Key E (2230) | Wi-Fi & Bluetooth (PCIe x1 + USB) |
| **ZED Link Mono** | MIPI CSI-2 (Ribbon) | Capture card for ZED X Stereo Camera (GMSL2) |

---

## 2. Software Architecture (What We Know)

### 2.1 The Zero-Copy DMABUF Pipeline (Architectural Intent)

This is the target architecture. End-to-end dma_buf trace confirming zero
CPU memcpy on the actual hot path has not been published; treat this as
a design goal until a verification artifact (dma_buf trace / perf
flamegraph) is added.

1. The ZED X driver allocates a **DMA Buffer** (`CONFIG_DMABUF_HEAPS_CMA`) and passes a File Descriptor (FD) to userspace.
2. The ZED Link Mono hardware writes raw camera frames directly into that RAM block via MIPI CSI.
3. The Jetson Hardware ISP reads the raw buffer and writes the processed RGB frame into a second DMA buffer.
4. The GStreamer pipeline or C++ application (`AxRuntime`) takes the FD of the RGB buffer and passes it to the Axelera driver.
5. The Axelera Metis DMA engine pulls the RGB frame directly from the Jetson's RAM across the PCIe bus into its AIPU.

### 2.2 Kernel Lobotomization & Real-Time Tuning
To guarantee deterministic execution and eliminate jitter, the kernel must be tuned for real-time (RT) operation:
- `PREEMPT_RT` patch ensures kernel code can be preempted.
- `CONFIG_NO_HZ_FULL=y` stops the scheduler clock ticks on isolated CPU cores.
- `nohz_full=1-5 isolcpus=1-5 rcu_nocbs=1-5 irqaffinity=0` boot parameters isolate cores 1-5 for inference pipelines, forcing core 0 to handle all system interrupts and OS garbage.
- `efi=noruntime` disables UEFI runtime services, which NVIDIA confirms cause latency spikes on RT kernels.

### 2.3 Driver Specifics
- **Stereolabs ZED X**: now built **in-tree** under `drivers/media/i2c/zedx/` via a Kconfig+Kbuild shim that symlinks back to the canonical `source/stereolabs/`. The deserializer is enforced to MAX9296 in both the defconfig (`CONFIG_SL_DESER_MAX9296=m`) and the vendor Makefile (`-DCONFIG_SL_DESER_MAX9296`). See `docs/DRIVERS.md` §1.
- **Axelera Metis**: now built **in-tree** under `drivers/misc/axelera/` via the same shim pattern; the vendor source remains the canonical copy at `source/axelera/axelera-driver/`. The `axl-jetson.patch` is applied if present and `LINK_WAIT_MAX_RETRIES` is forced to 100 regardless. The Voyager SDK userspace ships as pip wheels (numpy <2.0.0). See `docs/DRIVERS.md` §3.
- **ZED SDK**: userspace lives under `/usr/local/zed/`; installed at first-boot in `--skip_drivers` mode by `scripts/install_zed_sdk.sh` because we own a vermagic-aligned `sl_zedx.ko`. See `docs/DRIVERS.md` §2.

### 2.4 Vermagic Discipline
A custom RT kernel ships an incompatible vermagic with **every** stock NVIDIA / Stereolabs / Axelera pre-built module. Three-layer defense:

1. **In-tree build** of Metis + ZED X (vermagic match guaranteed by construction).
2. **Vermagic-aligned `linux-headers-5.15.x-tegra_*.deb`** produced in Phase 2, staged in Phase 3, installed at first-boot — DKMS-based third-party installers find headers under `/usr/src/linux-headers-$(uname -r)/`.
3. **Hard gates** at end of Phase 2 (`verify_vermagic.sh --build-tree`), in `pre_flash_audit.sh` (`--rootfs`), and on the live target in `verify_tuning.sh`. Any drift fails the audit before flashing.

Full strategy: `docs/VERMAGIC_STRATEGY.md`.

---

## 3. The Execution Plan (What We Need To Do)

This repository is designed for absolute, zero-touch automation via `Makefile`, encapsulated in a `Docker` container, and deployed via `systemd`. **Any AI agent inheriting this repository should default to using the `Makefile` targets.**

### Phase A: Host-Side Automation (The Makefile)

The full automation surface is exposed via Make. Run `make help` for the menu.

**Discovery & preflight**
*   **`make versions`** — print the pin manifest (versions, paths, USB IDs, RT tuning).
*   **`make doctor`** — preflight: confirm tarballs, external trees, host packages, Docker, sudo, network — *before* you waste 90 minutes on a doomed build.

**Build pipeline**
*   **`make docker-build`** — build the isolated Ubuntu 22.04 cross-compilation container (Bootlin toolchain, build tools).
*   **`make docker-shell`** — interactive shell inside the build container.
*   **`make extract`** — Phase 1: extracts L4T R36.5.0, applies all patches (PCIe retries, MAX9296, ZED X overlay, in-tree promotion of Metis + ZED X), injects defconfig (RT, CMA, DMABUF, hardening).
*   **`make build`** — Phase 2: cross-compiles kernel + every module + the `linux-headers-*.deb`. Captures `EXPECTED_VERMAGIC`, runs vermagic gate, writes `BUILD_MANIFEST.json`.
*   **`make bake`** — Phase 3: stages payloads (Voyager SDK, ZED SDK installer if present, ISP cals, headers .deb, systemd services) into the rootfs; injects RT boot args + ZED X overlay into `extlinux.conf`.
*   **`make audit`** — pre-flash gate. Vermagic + RT cmdline + DTBO presence. Exits non-zero on failure (CI-friendly).
*   **`make flash`** — Phase 4: writes NVMe via `l4t_initrd_flash.sh`. Requires Jetson in recovery mode.

**Composition**
*   **`make all`** — extract → build → bake.
*   **`make ignite-no-flash`** — doctor → all → audit. The full host-side pipeline; hardware not required.
*   **`make ignite`** — doctor → all → audit → flash → post-flash-validate. End-to-end.

**Validation & support**
*   **`make verify`** / **`make post-flash-validate`** — SSH to Jetson and run the full gauntlet (RT kernel active, isolcpus, CMA, vermagic of every critical module, lspci/lsmod hardware, /opt/av-env, ZED SDK, cyclictest p99 max < 100 µs — see [RT tuning](docs/RT_KERNEL_OPTIMIZATION.md) for full test conditions).
*   **`make headers`** — rebuild just the `linux-headers-*.deb` (useful when changing CONFIG_*).
*   **`make logs`** — bundle every log + manifest + remote dmesg/journal into a `support-bundle-*.tar.gz` for support requests.
*   **`make clean`** — remove `latest_jetson/` workspace.
*   **`make distclean`** — clean + remove Docker image + remove all logs/manifests.

### Phase B: Target-Side Execution (Zero-Touch Boot)

When the Jetson Orin NX boots for the first time after flashing, no manual login is required. The `jetson-first-boot.service` `systemd` daemon will automatically execute `scripts/jetson_first_boot.sh` which:
- Locks NVIDIA kernel/bootloader packages with `apt-mark hold` **and** an `/etc/apt/preferences.d/` entry (Pin-Priority: -1) — both layers are needed because hold can be overridden but pin -1 cannot.
- Installs the vermagic-aligned `linux-headers-*.deb` from `/opt/kernel-headers/` so any DKMS-based third-party installer can rebuild against the running kernel.
- Symlinks the OpenCV headers (`/usr/include/opencv4/opencv2` → `/usr/include/opencv2`).
- Builds `/opt/av-env` (Python venv) with `numpy<2.0.0`, PyTorch 2.7 from the Jetson wheel index, and Voyager SDK 1.6 (pip wheels — no DKMS).
- Runs `/opt/zed-sdk/install_zed_sdk.sh` if a `ZED_SDK_Tegra_*.run` is staged. Installer runs in `silent skip_drivers skip_python skip_cuda skip_tools` mode; `pyzed` lands in the venv.
- Edits `/boot/extlinux/extlinux.conf` to append `nohz_full=1-5 isolcpus=1-5 rcu_nocbs=1-5 irqaffinity=0 efi=noruntime pcie_aspm=off cma=2G`.
- Touches `/home/j/.jetson_initialized` to ensure idempotency.

Then a per-boot service (`jetson-rt-tune.service`, `scripts/jetson_rt_tune.sh`) runs on **every** boot to re-apply tuning that the firmware resets on power cycle: `nvpmodel -m 0` (MAXN), `jetson_clocks`, performance governor, GPU/EMC frequency lock, fan PWM 255, scheduler tuning, IRQ affinity (Metis→core 1, ZED X→core 2, NVMe→core 0), OOM shielding for Axelera runtime, and `tc fq` on the primary NIC.

### Phase C: Operations & Maintenance
- The first-boot script now writes `/etc/apt/preferences.d/99-jetson-av-kernel-lock` with `Pin-Priority: -1` for `nvidia-l4t-kernel*`, `nvidia-l4t-bootloader`, `nvidia-l4t-init`, `nvidia-l4t-xusb-firmware`. Even an explicit `apt install <pkg>=<ver>` is rejected.
- Never run `sudo apt upgrade nvidia-jetpack`.
- If `/boot/extlinux/extlinux.conf` is ever overwritten, run `sudo /home/j/jetson_first_boot.sh` again (it's idempotent except for the marker — `rm /home/j/.jetson_initialized` first if you need it to fully re-execute).
- Always verify after any change with `sudo /home/j/verify_tuning.sh` — it now also dumps vermagic of the critical modules.

### Documentation map

**Start here**
| Doc | Purpose |
|---|---|
| [`docs/QUICKSTART.md`](docs/QUICKSTART.md) | Zero to flashed Jetson in 90 minutes |
| [`docs/RUNBOOK.md`](docs/RUNBOOK.md) | Operational decision trees (repeat deploys, recovery) |
| [`docs/AUTOMATION.md`](docs/AUTOMATION.md) | How Makefile + scripts + `versions.env` compose |
| [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md) | Symptom-first failure modes |

**Production phases (Phase 5/6/7)**
| Doc | Purpose |
|---|---|
| [`docs/FLEET.md`](docs/FLEET.md) | Phase 6 — fleet manufacturing for N units (release-tarball flow) |
| [`docs/GOLDEN_IMAGE.md`](docs/GOLDEN_IMAGE.md) | Clone a fully-customized Jetson and redeploy bit-identical copies to N units |
| [`docs/NVIDIA_REFERENCES.md`](docs/NVIDIA_REFERENCES.md) | Annotated index of NVIDIA / vendor canonical docs |
| [`docs/COMMUNITY_POST.md`](docs/COMMUNITY_POST.md) | The bible-grade long-form guide — companion to the original Axelera community tutorial |
| [`docs/UAV_RESILIENCE.md`](docs/UAV_RESILIENCE.md) | Phase 7 — watchdog, persistent journald, kdump, security, time sync, brownout guard, PCIe AER |
| [`docs/FINE_TUNING.md`](docs/FINE_TUNING.md) | Cross-component coordination — power.conf, storage.conf, expectations.conf, axrun, CPU map, per-device CMA strategy |
| [`docs/BLACKBOX.md`](docs/BLACKBOX.md) | Phase 7 — black-box recorder (event log + ROS bag + hash chain) |
| [`docs/DATA_PARTITION.md`](docs/DATA_PARTITION.md) | Phase 7 — single-NVMe btrfs data partition (compression, scrub, snapshots) |
| [`docs/CUDA_LIBS.md`](docs/CUDA_LIBS.md) | Phase 5 — OpenCV/OpenGL/CUDA/TensorRT/VPI userspace |
| [`docs/AV_STACK.md`](docs/AV_STACK.md) | Phase 5 — ROS 2 + Isaac ROS + cuVSLAM + nvblox + Nav2 mission launch |
| [`docs/VERIFICATION.md`](docs/VERIFICATION.md) | The pre/post-check framework powering every phase |
| [`docs/VERIFICATION_REPORT.md`](docs/VERIFICATION_REPORT.md) | Audit of every magic value/URL/CONFIG against vendor sources (May 2026) |

**Reference**
| Doc | Purpose |
|---|---|
| [`docs/BUILD.md`](docs/BUILD.md) | Build phase mechanics + reproducibility |
| [`docs/FLASH.md`](docs/FLASH.md) | Flash phase mechanics |
| [`docs/KERNEL_PATCHES.md`](docs/KERNEL_PATCHES.md) | Every patch & in-tree integration |
| [`docs/KERNEL_OPTIMIZATIONS.md`](docs/KERNEL_OPTIMIZATIONS.md) | Every CONFIG_* flag and why |
| [`docs/RT_KERNEL_OPTIMIZATION.md`](docs/RT_KERNEL_OPTIMIZATION.md) | Real-time tuning recipes |
| [`docs/VERMAGIC_STRATEGY.md`](docs/VERMAGIC_STRATEGY.md) | **Must-read** — vermagic discipline |
| [`docs/DRIVERS.md`](docs/DRIVERS.md) | All vendor drivers: ZED X + ZED SDK + Axelera Metis + Voyager SDK |

---

## Enabling the GitHub Pages site

If you've forked this repo and want the docs site on your own GitHub
Pages namespace:

1. **Settings → Pages → Build and deployment**
   - **Source**: `Deploy from a branch`
   - **Branch**: `main`  /  `/docs`
   - Save.
2. Edit [`docs/_config.yml`](docs/_config.yml) — change `url` and
   `baseurl` to match your fork (e.g. `https://yourname.github.io` and
   `/your-repo-name`).
3. Push. The site builds in ~2 min and goes live at
   `https://<you>.github.io/<repo>/`.

To preview the site locally before pushing:

```bash
cd docs
bundle install
bundle exec jekyll serve
# open http://127.0.0.1:4000/jetson-rt-stack
```

The theme is [`just-the-docs`](https://just-the-docs.com/), pulled as a
remote theme — no vendoring required. Sidebar navigation,
search, and code highlighting are automatic; the order pages appear in
the sidebar is controlled by `nav_order:` in each doc's front matter.
