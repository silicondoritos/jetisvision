---
title: Kernel Patches
layout: default
description: "All patches applied to the L4T R36.5 kernel source: PCIe retries, MAX9296 deserializer, ZED X overlay, Metis in-tree promotion."
nav_order: 13
---

# Kernel Patches & Source Modifications

All changes are applied by `scripts/01_extract_and_patch.sh` (Phase 1) and `scripts/02_build_kernel.sh` (Phase 2). Every operation is idempotent — safe to re-run on an existing workspace.

---

## 1. PCIe Patience Patch (Critical — Axelera cold-boot)

**File**: `source/kernel/kernel-jammy-src/drivers/pci/controller/dwc/pcie-designware.h`

```c
// Stock NVIDIA (10 retries → Axelera Metis invisible on cold boot)
#define LINK_WAIT_MAX_RETRIES  10

// This build
#define LINK_WAIT_MAX_RETRIES  100
```

Applied via `voyager-sdk/axl-jetson.patch` if present, then forced to 100 with `sed` regardless. Without this patch, `lspci` returns nothing for the Axelera M.2 slot on cold power-up.

---

## 2. ZED X MAX9296 Deserializer Fix (Critical — frame integrity)

The ZED Link Mono adapter uses a **MAX9296** GMSL2 deserializer. Stereolabs' default build selects MAX96712 — a different chip. The wrong driver produces silently corrupted frames with no error visible to userspace.

**R36.5 structure** (Kconfig-driven — no top-level `stereolabs/Makefile`):

Two changes required:

**1 — kernel defconfig** (`source/kernel/kernel-jammy-src/arch/arm64/configs/defconfig`):
```
CONFIG_SL_DESER_MAX9296=m
# CONFIG_SL_DESER_MAX96712 is not set
```
Added as part of the AV kernel config block (Section 7).

**2 — compiler flag** (`source/stereolabs/drivers/Makefile`):
```makefile
# before
subdir-ccflags-y += -DCONFIG_SL_DESER_MAX96712
# after
subdir-ccflags-y += -DCONFIG_SL_DESER_MAX9296
```
Applied via `sed` in Phase 1.

> **Note**: In L4T ≤R35.x the fix was in a top-level `stereolabs/Makefile` (`export CONFIG_SL_DESER_MAX96712=m` → `MAX9296`). That file does not exist in R36.5 — the selection moved to Kconfig. Old docs/scripts referencing `stereolabs/Makefile` are wrong for this build.

---

## 3. ZED X R36.5 Kernel Patches

**Source**: `zedx-driver/nvidia_kernel/kernel_patches/R36.5/0*.patch`

Applied with `patch -p2 -N` (skips already-applied). Excludes `zedbox` variants — this build targets **ZED Link Mono** only. Patches integrate the ZED X driver sources and Makefiles into the NVIDIA kernel OOT build tree.

---

## 4. ZED X Driver Injection

**Source directories** → **Destination in kernel tree**:

| Source | Destination |
|--------|-------------|
| `zedx-driver/src/kernel/stereolabs/` | `source/stereolabs/` |
| `zedx-driver/src/hardware/stereolabs/` | `source/hardware/stereolabs/` |
| `zedx-driver/src/hardware/stereolabs/overlay/*.dts` | `source/hardware/nvidia/t23x/nv-public/` |
| `zedx-driver/src/hardware/stereolabs/overlay/*.dtsi` | `source/hardware/nvidia/t23x/nv-public/` |

The overlay DTS files are relocated into `nv-public/` directly (the **Relocation Protocol**) to avoid recursion limits in NVIDIA's OOT DTS build system.

---

## 5. nv-public Makefile dtbo-y Correction

**File**: `source/hardware/nvidia/t23x/nv-public/Makefile`

The ZED X R36.5 patches register overlay targets using `dtbo-y += $(makefile-path)/...`. The `nv-public/Makefile` also has an `addprefix $(makefile-path)/` block that runs unconditionally — producing a double-prefix path (`t23x/nv-public/t23x/nv-public/...`) that the build system cannot resolve.

Phase 1 applies a `sed` correction after patching:

```bash
# Strips the pre-set $(makefile-path)/ from dtbo-y entries so the
# addprefix block adds it exactly once
sed -i 's|dtbo-y += \$(makefile-path)/\(.*-sl-overlay\.dtbo\)|dtbo-y += \1|g' \
    Linux_for_Tegra/source/hardware/nvidia/t23x/nv-public/Makefile
```

> **Note**: Even with the correct path, the NVIDIA `kernel-devicetree` build system never compiles `dtbo-y` targets — see Section 7 below.

---

## 6. Axelera Metis Driver — In-Tree Promotion

**Source**: `axelera-driver/` → `source/axelera/axelera-driver/`

The vendor source is rsynced into `source/axelera/axelera-driver/` *and then promoted to in-tree* by writing a Kconfig + Kbuild stub under `source/kernel/kernel-jammy-src/drivers/misc/axelera/`:

```
drivers/misc/axelera/
├── Kconfig                   ← defines CONFIG_AXELERA_METIS
├── Makefile                  ← obj-$(CONFIG_AXELERA_METIS) += metis-wrapper/
├── metis-src                 ← symlink → source/axelera/axelera-driver/
└── metis-wrapper/
    └── Makefile              ← include $(VENDOR_DIR)/Makefile
```

The kernel's own `make modules` discovers the new sub-tree, recurses through the wrapper, and invokes the vendor Makefile under our `CROSS_COMPILE`, `ARCH`, and `KERNEL_HEADERS`. The resulting `metis.ko` shares an identical vermagic with the kernel — no DKMS, no toolchain drift. See `docs/VERMAGIC_STRATEGY.md`.

The `drivers/misc/Kconfig` and `drivers/misc/Makefile` are wired by Phase 1 with `sed`/`tee`:

```
# drivers/misc/Kconfig (insert before final endmenu)
source "drivers/misc/axelera/Kconfig"

# drivers/misc/Makefile (append)
obj-$(CONFIG_AXELERA_METIS) += axelera/
```

Defconfig flag: `CONFIG_AXELERA_METIS=m` (Section 7).

Udev rules (`72-axelera.rules`) are also staged into `rootfs/etc/udev/rules.d/` during Phase 1.

---

## 6b. ZED X Driver — In-Tree Promotion

Same strategy as Metis. Phase 1 generates:

```
drivers/media/i2c/zedx/
├── Kconfig                   ← VIDEO_ZEDX, VIDEO_ZEDX_AR0234, VIDEO_ZEDX_IMX678,
│                                SL_DESER_MAX9296, SL_DESER_MAX96712 (default n)
├── Makefile                  ← obj-$(CONFIG_VIDEO_ZEDX) += zedx-wrapper/
├── zedx-src                  ← symlink → source/stereolabs/
└── zedx-wrapper/
    └── Makefile              ← include $(VENDOR_DIR)/Makefile
```

Wired into `drivers/media/i2c/Kconfig` and `drivers/media/i2c/Makefile`. Defconfig flags: `CONFIG_VIDEO_ZEDX=m`, `CONFIG_VIDEO_ZEDX_AR0234=m`, `CONFIG_VIDEO_ZEDX_IMX678=m`. The MAX9296 / MAX96712 selection is now Kconfig-controlled (with MAX96712 default-off).

The result: `sl_zedx.ko` and the deserializer module are produced by the kernel's `make modules` step and inherit its vermagic. The legacy out-of-tree path under `source/stereolabs/` is preserved as the canonical source via the `zedx-src` symlink, so vendor patches still apply where the upstream Stereolabs build expects them.

---

## 7. AV Kernel Config Injection

**File**: `source/kernel/kernel-jammy-src/arch/arm64/configs/defconfig`

Appended once (idempotent check on `CONFIG_PREEMPT_RT=y`). Key additions:

| Config | Value | Reason |
|--------|-------|--------|
| `CONFIG_SL_DESER_MAX9296` | m | ZED Link Mono MAX9296 deserializer (see Section 2) |
| `CONFIG_SL_DESER_MAX96712` | not set | Wrong deserializer — corrupts frames silently |
| `CONFIG_PREEMPT_RT` | y | Full real-time preemption |
| `CONFIG_NO_HZ_FULL` | y | Tickless on cores 1–5 |
| `CONFIG_HZ_1000` | y | 1ms timer resolution |
| `CONFIG_CPU_ISOLATION` | y | Kernel enforcement of isolcpus |
| `CONFIG_RCU_NOCB_CPU` | y | RCU callbacks off isolated cores |
| `CONFIG_IRQ_FORCED_THREADING` | y | All IRQ handlers threaded |
| `CONFIG_CMA_SIZE_MBYTES` | 2048 | 2GB contiguous memory (was 32!) |
| `CONFIG_HUGETLB_PAGE` | y | HugePages for AI/Vision buffers |
| `CONFIG_DMABUF_HEAPS` | y | Zero-copy DMA framework |
| `CONFIG_DMABUF_HEAPS_CMA` | y | CMA heap for camera→NPU path |
| `CONFIG_PCIEASPM` | not set | PCIe always-on (no link power management) |
| `CONFIG_RTW88_8822CE` | m | Realtek Wi-Fi (M.2 Key E) |
| `CONFIG_EDAC_TEGRA` | y | ECC memory monitoring |
| `CONFIG_PSTORE_RAM` | y | Black-box crash logging |
| `CONFIG_KASAN` | not set | Strip debug overhead / jitter |
| `CONFIG_DYNAMIC_FTRACE` | not set | Strip debug overhead / jitter |

PREEMPT_RT is then formally enabled via NVIDIA's `generic_rt_build.sh "enable"`.

> **Full catalogue**: see `docs/KERNEL_OPTIMIZATIONS.md`. The defconfig block now contains 16 thematic groups (RT, ZED X, DMABUF, ARMv8.5, hardening, RT depth, memory/cache, cgroups v2, networking, I/O, Wi-Fi, module discipline, hardening, in-tree drivers, PCIe, debug strip, filesystems).

---

## 8. ZED X Overlay DTBO: Direct dtc Compilation (Phase 2)

**Why this is necessary** — three compounding issues in the NVIDIA build system:

1. `kernel-devicetree/scripts/Makefile.lib` adds `dtb-y` to `always-y` but **never adds `dtbo-y`**. Overlay targets in `dtbo-y` are registered but never built.
2. The ZED X overlay DTS uses `#ifdef BUILDOVERLAY` to conditionally emit `/dts-v1/; /plugin/;`. Without `-DBUILDOVERLAY`, the output is a malformed empty blob.
3. DTC 1.5.x (Ubuntu 20.04 host) reports `duplicate_label` errors on overlay DTS files. These are false positives — the same label appears in both the fragment overlay body and a base-tree cross-reference, which is valid in overlay context. The NVIDIA kernel-built `dtc` handles this without error; the host system `dtc` requires `-f` to force output.

**Solution in `02_build_kernel.sh`**: after `make dtbs`, the build script compiles the DTBO directly:

```bash
cpp -E -DBUILDOVERLAY -DLINUX_VERSION=600 -DTEGRA_HOST1X_DT_VERSION=2 \
    -x assembler-with-cpp -nostdinc \
    -I<hw-nvidia>/t23x/nv-public \
    -I<hw-nvidia>/t23x/nv-public/include/kernel \
    -I<hw-nvidia>/tegra/nv-public \
    -I<kernel-src>/include \
    -o /tmp/zedlink-mono.dts.tmp \
    <hw-nvidia>/t23x/nv-public/tegra234-p3768-camera-zedlink-mono-sl-overlay.dts

$DTC_BIN -@ -f -I dts -O dtb \
    -o Linux_for_Tegra/kernel/dtb/tegra234-p3768-camera-zedlink-mono-sl-overlay.dtbo \
    /tmp/zedlink-mono.dts.tmp
```

The `-@` flag enables the `__symbols__` node required for overlay label resolution at boot. The `-f` flag suppresses the duplicate_label false positives.

---

## 9. Vermagic Discipline (Module Loadability Gate)

A kernel patched as heavily as this one ships with a vermagic string that is incompatible with **any** stock NVIDIA / Stereolabs / Axelera pre-built module. The build pipeline now enforces vermagic alignment at three checkpoints:

1. **End of Phase 2** — `verify_vermagic.sh --build-tree` walks every `.ko` produced by `make modules` (kernel + ZED X + Metis), confirms they all share one vermagic, and writes the expected value to `latest_jetson/Linux_for_Tegra/EXPECTED_VERMAGIC`.
2. **`pre_flash_audit.sh`** — re-runs the gate against `$ROOTFS/lib/modules/` and exits 1 on any mismatch.
3. **Live target (`verify_tuning.sh`)** — modinfo-checks `sl_zedx.ko`, `metis.ko`, `max9296.ko` against the running `uname -r`.

A **vermagic-aligned `linux-headers-5.15.x-tegra_*.deb`** is also produced by Phase 2 (`make bindeb-pkg`), staged in Phase 3 (`/opt/kernel-headers/`), and `dpkg -i`'d at first boot. This is the only way ZED SDK / Voyager DKMS-based installers can succeed on this kernel.

See `docs/VERMAGIC_STRATEGY.md` for the full strategy.

---

## Verification

After Phase 2 completes, verify all patches are active before flashing:

```bash
# PCIe patience
grep LINK_WAIT_MAX_RETRIES \
  latest_jetson/Linux_for_Tegra/source/kernel/kernel-jammy-src/drivers/pci/controller/dwc/pcie-designware.h
# → 100

# Correct deserializer (defconfig is the new home in R36.5)
grep "CONFIG_SL_DESER_MAX9296" \
  latest_jetson/Linux_for_Tegra/source/kernel/kernel-jammy-src/arch/arm64/configs/defconfig
# → CONFIG_SL_DESER_MAX9296=m

# CMA reservation
grep CMA_SIZE_MBYTES \
  latest_jetson/Linux_for_Tegra/source/kernel/kernel-jammy-src/arch/arm64/configs/defconfig
# → CONFIG_CMA_SIZE_MBYTES=2048

# In-tree integrations
grep -E "CONFIG_(AXELERA_METIS|VIDEO_ZEDX)" \
  latest_jetson/Linux_for_Tegra/source/kernel/kernel-jammy-src/arch/arm64/configs/defconfig
# → CONFIG_AXELERA_METIS=m, CONFIG_VIDEO_ZEDX=m, ...

# Vermagic captured
cat latest_jetson/Linux_for_Tegra/EXPECTED_VERMAGIC
# → 5.15.x-tegra SMP preempt_rt mod_unload aarch64

# Headers .deb produced
ls -lh latest_jetson/Linux_for_Tegra/staging/kernel-headers/linux-headers-*.deb

# ZED X DTBO present
ls -lh latest_jetson/Linux_for_Tegra/kernel/dtb/tegra234-p3768-camera-zedlink-mono-sl-overlay.dtbo
# → ~79K

# Vermagic gate (build tree)
./scripts/verify_vermagic.sh --build-tree

# Full audit
./scripts/pre_flash_audit.sh
# → Full green banner; exit 0
```
