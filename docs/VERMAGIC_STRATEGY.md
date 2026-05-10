---
title: Vermagic Strategy
layout: default
description: "Must-read: why vermagic breaks all pre-built kernel modules on a custom RT kernel and the three-layer defense that prevents it."
nav_order: 16
---

# Vermagic Strategy

Vermagic is the most common reason custom RT kernel deployments fail at runtime. This doc covers what it is, how it affects this platform, and the three-layer defense the build pipeline enforces.

## TL;DR

1. Every `.ko` carries a 64-byte **vermagic** string and (with `CONFIG_MODVERSIONS=y`)
   a per-symbol CRC table. The kernel's module loader rejects any module
   whose vermagic doesn't match its own, and any module whose imported
   symbol CRCs don't match the kernel's exported symbols.
2. Stock NVIDIA / Stereolabs / Axelera pre-built modules **WILL NOT LOAD**
   on this kernel — the `preempt_rt` flag and `LOCALVERSION=-tegra`
   guarantee a mismatch.
3. The build pipeline now uses a three-layer defense: **in-tree build** for
   our own drivers (Metis, ZED X), **vermagic-aligned `linux-headers-*.deb`**
   shipped in the rootfs for any third-party DKMS installer, and **automated
   gates** (`verify_vermagic.sh`, `pre_flash_audit.sh`) that hard-fail the
   build before flashing if anything drifts.

---

## What vermagic actually is

When `make modules` builds a `.ko`, the kernel build system embeds a string
of the form:

```
<UTS_RELEASE> SMP <preempt_mode> mod_unload <arch> [features]
```

Concrete example for this platform:

```
5.15.148-tegra SMP preempt_rt mod_unload aarch64
```

Constituent parts:

| Field           | Value here              | Source                                  |
|----------------|-------------------------|-----------------------------------------|
| `UTS_RELEASE`  | `5.15.148-tegra` | `KERNELVERSION` + `LOCALVERSION`        |
| SMP            | `SMP`                   | `CONFIG_SMP=y`                          |
| Preempt mode   | `preempt_rt`            | `CONFIG_PREEMPT_RT=y`                   |
| Module unload  | `mod_unload`            | `CONFIG_MODULE_UNLOAD=y`                |
| Architecture   | `aarch64`               | `ARCH=arm64`                            |

When `insmod` or `modprobe` loads a `.ko`, the kernel reads the module's
embedded vermagic and compares it byte-for-byte to its own. **Any
difference → `Invalid module format`.** No retry. No useful error.

`CONFIG_MODVERSIONS=y` adds a stricter check: every symbol the module
imports must have a CRC matching the kernel's `Module.symvers` entry for
that symbol. This catches subtle ABI drift (e.g., a struct field being
added) even when vermagic happens to match.

## Why this platform makes vermagic harder

Three knobs combined make our vermagic uniquely incompatible with anything
the rest of the world ships:

1. **`LOCALVERSION=-tegra`** (`scripts/02_build_kernel.sh:19`)
   Stamps `-tegra` into `UTS_RELEASE`, so our kernel release name
   is `5.15.x-tegra`, not `5.15.x-tegra` (NVIDIA stock).
2. **`CONFIG_PREEMPT_RT=y`** (`scripts/01_extract_and_patch.sh:147`)
   Replaces the preempt-mode token from `preempt` (NVIDIA default) to
   `preempt_rt`. **This change alone breaks every NVIDIA-shipped module.**
3. **Bootlin toolchain `aarch64-buildroot-linux-gnu-2022.08-1`**
   (`Dockerfile`) — its GCC fingerprint differs from NVIDIA's. With
   `CONFIG_MODVERSIONS=y`, even a tiny inline-codegen difference can change
   exported-symbol CRCs.

## Where it bites

| Source of `.ko`                                    | Vermagic outcome                                          | Mitigation in this repo                                                                |
|---------------------------------------------------|-----------------------------------------------------------|----------------------------------------------------------------------------------------|
| Stock `nvidia-l4t-kernel-modules.deb` from apt    | ❌ MISMATCH (`preempt` vs `preempt_rt`)                   | `apt-mark hold` + `apt preferences Pin-Priority: -1` (first-boot)                      |
| Pre-built Stereolabs `.deb` from their PPA        | ❌ MISMATCH                                               | Build `sl_zedx.ko` ourselves, in-tree (`drivers/media/i2c/zedx/`)                      |
| Voyager SDK `install.sh --driver` DKMS rebuild    | ⚠️ Conditional — needs our headers `.deb`                 | Ship `linux-headers-5.15.x-tegra_*.deb` and `dpkg -i` it at first-boot           |
| ZED SDK `.run` installer DKMS rebuild             | ⚠️ Conditional — same                                     | Same as above + `install_zed_sdk.sh` runs installer in `runtime_only` mode             |
| Our Phase-2 in-tree builds                        | ✅ Always matches                                         | Sole source of truth                                                                   |

## The three-layer defense

```
┌──────────────────────────────────────────────────────────────────────┐
│ Layer 1: IN-TREE WHERE POSSIBLE                                      │
│ The kernel's own `make modules` builds the .ko. Same toolchain,      │
│ same headers, same Module.symvers. Vermagic match is guaranteed.     │
│                                                                      │
│   • Metis  → drivers/misc/axelera/         (CONFIG_AXELERA_METIS=m)  │
│   • ZED X  → drivers/media/i2c/zedx/       (CONFIG_VIDEO_ZEDX=m)     │
│   • MAX9296 deserializer → same Kconfig     (CONFIG_SL_DESER_MAX9296)│
└──────────────────────────────────────────────────────────────────────┘
                                  │
                                  ▼
┌──────────────────────────────────────────────────────────────────────┐
│ Layer 2: SHIP MATCHING HEADERS FOR THIRD-PARTY DKMS                  │
│ The ZED SDK and Voyager SDK installers default to building modules   │
│ via DKMS against the running kernel. They look for:                  │
│   /usr/src/linux-headers-$(uname -r)/                                │
│ We produce linux-headers-5.15.x-tegra_*.deb in Phase 2,       │
│ stage it in /opt/kernel-headers/ in Phase 3, and install it at       │
│ first-boot before any installer runs. DKMS now works.                │
└──────────────────────────────────────────────────────────────────────┘
                                  │
                                  ▼
┌──────────────────────────────────────────────────────────────────────┐
│ Layer 3: GATES THAT HARD-FAIL ON DRIFT                               │
│   • End of Phase 2: verify_vermagic.sh --build-tree                  │
│     scans every .ko in the build tree, fails if any drift.           │
│   • pre_flash_audit.sh: scans $ROOTFS/lib/modules, exits 1 on        │
│     any mismatch. `make flash` should not be run otherwise.          │
│   • verify_tuning.sh on the live target: dumps vermagic of           │
│     sl_zedx, metis, max9296 and reports mismatch if uname doesn't    │
│     appear in the module's vermagic string.                          │
└──────────────────────────────────────────────────────────────────────┘
```

## Operational rules

These are inviolable. A single violation re-introduces the trap.

1. **Never `apt install` any `nvidia-l4t-kernel*` or `nvidia-l4t-bootloader`
   package.** The first-boot script holds and pins them to `-1`. If you
   ever see a prompt offering to upgrade these, decline.
2. **Never `insmod --force`.** The flag bypasses vermagic and almost
   always loads a module that proceeds to corrupt kernel memory.
3. **Never use a `.ko` built outside the Docker container.** Same source +
   same toolchain + same kernel headers = vermagic match. Anything else
   is gambling.
4. **Re-run Phase 2 if any of these change:**
   - `LOCALVERSION` or any kernel `CONFIG_*` value
   - Bootlin toolchain version
   - The Docker image (`make docker-build`)
   - Any patch under `01_extract_and_patch.sh`
5. **Re-bake (Phase 3) and re-flash (Phase 4) after Phase 2.** A new kernel
   with old modules in the rootfs is the most common drift scenario.

## Diagnosing a vermagic failure post-deployment

Symptom: `dmesg | grep "Invalid module format"`, or a service that depends on
a module silently fails to start.

```bash
# 1. Show the running kernel's vermagic
cat /proc/version
cat /sys/module/vermagic 2>/dev/null   # not always present

# 2. Show the rejected module's vermagic
modinfo /path/to/the.ko | grep vermagic

# 3. Walk all installed modules
sudo /home/j/verify_tuning.sh
```

If even one of `sl_zedx.ko`, `metis.ko`, or `max9296.ko` shows a vermagic
that doesn't include the running `uname -r`, the rootfs and kernel are
mismatched. Re-flash with a fresh Phase 2 + Phase 3 build.

## Appendix: where each rule is enforced in code

| Rule                                  | File / line                                                |
|---------------------------------------|------------------------------------------------------------|
| `LOCALVERSION=-tegra`          | `scripts/02_build_kernel.sh:19`                            |
| `CONFIG_PREEMPT_RT=y`                 | `scripts/01_extract_and_patch.sh:147`                      |
| `CONFIG_MODVERSIONS=y`                | `scripts/01_extract_and_patch.sh` (defconfig block)        |
| `CONFIG_MODULE_FORCE_LOAD` not set    | `scripts/01_extract_and_patch.sh` (defconfig block)        |
| `apt-mark hold` of NVIDIA kernel pkgs | `scripts/jetson_first_boot.sh:18-25`                       |
| `apt preferences Pin-Priority: -1`    | `scripts/jetson_first_boot.sh` (apt prefs block)           |
| `EXPECTED_VERMAGIC` capture           | `scripts/02_build_kernel.sh` (after `l4t_update_initrd`)   |
| Build-tree vermagic gate              | `scripts/verify_vermagic.sh --build-tree`                  |
| Rootfs vermagic gate                  | `scripts/pre_flash_audit.sh` (vermagic section)            |
| Headers `.deb` build                  | `scripts/02_build_kernel.sh` (`make bindeb-pkg`)           |
| Headers `.deb` install                | `scripts/jetson_first_boot.sh` (after apt holds)           |
| Metis in-tree integration             | `scripts/01_extract_and_patch.sh` (axelera block)          |
| ZED X in-tree integration             | `scripts/01_extract_and_patch.sh` (zedx block)             |
| Live-target vermagic dump             | `scripts/verify_tuning.sh` (Module Vermagic Sanity)        |
| ZED SDK runtime_only mode             | `scripts/install_zed_sdk.sh`                               |
