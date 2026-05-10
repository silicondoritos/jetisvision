---
title: Drivers
layout: default
description: "Vendor driver integrations: ZED X in-tree, ZED SDK userspace, Axelera Metis in-tree, Voyager SDK pip wheels. Acquisition instructions for NDA-gated trees."
nav_order: 17
---

# Drivers

ZED X (camera + ZED Link Mono GMSL2 deserializer + ZED SDK) and Axelera Metis M.2 PCIe (+ Voyager SDK).

See also: [Configuration]({{ '/CONFIGURATION' | relative_url }}) · [Kernel patches]({{ '/KERNEL_PATCHES' | relative_url }}) · [Vermagic]({{ '/VERMAGIC_STRATEGY' | relative_url }}) · [Verification report]({{ '/VERIFICATION_REPORT' | relative_url }})

---

## Vendor tree acquisition

None of the following are included in this repository. They are proprietary, NDA-gated, or require a vendor relationship. Place them adjacent to the repo at the paths shown — the build system reads them from there.

| Tree | Path | What it is | How to get it |
|---|---|---|---|
| `axelera-driver/` | `$REPO_ROOT/axelera-driver/` | Axelera Metis PCIe kernel driver source | Contact Axelera support — NDA required |
| `voyager-sdk/` | `$REPO_ROOT/voyager-sdk/` | Axelera Voyager SDK + `axl-jetson.patch` | Same NDA package — contact Axelera support |
| `zedx-driver/` | `$REPO_ROOT/zedx-driver/` | Stereolabs ZED X + ZED Link kernel driver source | Stereolabs business / NDA relationship — contact [support.stereolabs.com](https://support.stereolabs.com) |
| `zed-sdk/` | `$REPO_ROOT/zed-sdk/` | ZED SDK installer (`.run`) | Public download — [stereolabs.com/developers/release](https://www.stereolabs.com/developers/release) |

All four directories are in `.gitignore`. The build proceeds without any that are absent — features are skipped per the active configuration:

```bash
make menuconfig   # set CAMERA_NONE to skip ZED X; disable AXELERA_METIS to skip Metis
make defconfig    # use committed defaults
make doctor       # confirms which trees are present, PASS/WARN/FAIL per feature
```

**Pre-compiled `.ko` modules will not load** on this build's custom PREEMPT_RT kernel due to vermagic mismatch. The vendor source must be compiled in-tree against this kernel's own toolchain, headers, and Module.symvers. That is what this build system does automatically when the vendor tree is placed at the correct path.

---

---

## 1. Stereolabs ZED X (camera + deserializer)

The ZED X is a 4K@30 fps stereo camera connected via:

```
ZED X sensor
  └── GMSL2 over coax
       └── ZED Link Mono adapter (MAX9296 deserializer)
            └── MIPI CSI-2 ribbon
                 └── Jetson VI / ISP
```

### 1.1 Build path

Promoted to **in-tree** under `drivers/media/i2c/zedx/` by Phase 1
(`scripts/01_extract_and_patch.sh`). The vendor source under `source/stereolabs/`
remains canonical via a symlink (`zedx-src`); the in-tree shim's Kconfig +
Kbuild glue makes the kernel's own `make modules` build it with the same
toolchain as the kernel image.

| Component | Kconfig flag | Notes |
|---|---|---|
| Top-level driver | `CONFIG_VIDEO_ZEDX=m` | sl_zedx.ko |
| AR0234 sensor | `CONFIG_VIDEO_ZEDX_AR0234=m` | onsemi |
| IMX678 sensor | `CONFIG_VIDEO_ZEDX_IMX678=m` | Sony |
| MAX9296 deserializer | `CONFIG_SL_DESER_MAX9296=m` | **required** for ZED Link Mono |
| MAX96712 deserializer | `CONFIG_SL_DESER_MAX96712` (off) | wrong chip — silently corrupts frames |

Vermagic match is guaranteed by construction. See
[`VERMAGIC_STRATEGY.md`](VERMAGIC_STRATEGY.md) for why this matters.

### 1.2 The MAX9296 vs MAX96712 silent-corruption trap

**ZED Link Mono uses the MAX9296.** Selecting MAX96712 (a different chip)
compiles cleanly, the module loads cleanly, frames flow at 30 fps with no
errors in dmesg — but the frame contents are subtly wrong. Stereo depth
produces garbage. SLAM drifts. Inference behaves erratically.

We enforce the correct choice in two places:

1. **Defconfig**: `CONFIG_SL_DESER_MAX9296=m`,
   `# CONFIG_SL_DESER_MAX96712 is not set`.
2. **Compiler flag in `source/stereolabs/drivers/Makefile`**:
   `-DCONFIG_SL_DESER_MAX96712 → -DCONFIG_SL_DESER_MAX9296` via `sed`
   in Phase 1.

Both must be in place — the Makefile flag overrides the Kconfig if they
disagree.

### 1.3 Device-tree overlay

`tegra234-p3768-camera-zedlink-mono-sl-overlay.dtbo` is compiled in Phase 2
by an explicit `cpp -DBUILDOVERLAY ... | dtc -@ -f` sequence — NVIDIA's
`kernel-devicetree` system silently skips `dtbo-y` targets, so the standard
kernel build won't produce it. See [`KERNEL_PATCHES.md`](KERNEL_PATCHES.md) §8.

The overlay is registered in `extlinux.conf` by Phase 3:

```
APPEND ${cbootargs} ...
OVERLAYS /boot/tegra234-p3768-camera-zedlink-mono-sl-overlay.dtbo
```

### 1.4 ISP calibrations

`zedx-driver/ISP/*.isp` files are baked into `/var/nvidia/nvcam/settings/`
by Phase 3. NVIDIA's `nvcam` daemon loads them at boot to tune the ISP
pipeline (exposure, white-balance, lens shading) for the specific sensor
in use (AR0234 or IMX678).

Symptoms of missing/wrong `.isp`: frames are usable but visually off
(washed-out, wrong color balance, dark corners). Check `dmesg | grep nvcam`
and `ls /var/nvidia/nvcam/settings/`.

### 1.5 Verification on target

```bash
# Kernel module loaded with vermagic match (only if you have driver source)
lsmod | grep sl_zedx
modinfo sl_zedx | grep vermagic   # must contain $(uname -r)

# v4l2 enumeration
v4l2-ctl --list-devices

# Camera registered
ls /dev/video*

# Live capture (5 s)
sudo gst-launch-1.0 -v nvarguscamerasrc num-buffers=150 ! \
    'video/x-raw(memory:NVMM),width=1920,height=1080,framerate=30/1' ! \
    fakesink

# ISP calibrations present
ls /var/nvidia/nvcam/settings/*.isp
```

---

## 2. ZED SDK (userspace)

The ZED SDK is **userspace** — but its installer ships a DKMS-built kernel
module (`sl_zedx.ko`). On a custom RT kernel that's a vermagic landmine
unless we intervene.

### 2.1 Layout on the rootfs

```
/opt/zed-sdk/
├── ZED_SDK_Tegra_*.run       ← Stereolabs installer (place here pre-bake)
└── install_zed_sdk.sh        ← Our wrapper, runs at first-boot
/opt/kernel-headers/
└── linux-headers-5.15.x-tegra_*.deb   ← vermagic-aligned headers
```

### 2.2 How the install works

`scripts/install_zed_sdk.sh` (run by `jetson_first_boot.sh`) does this in
order:

1. **Verify our `sl_zedx.ko` is present and vermagic-aligned.** If
   `CONFIG_VIDEO_ZEDX=m` was honored by `make modules`, the module lives
   at `/lib/modules/$(uname -r)/kernel/drivers/media/i2c/zedx/...`. If
   not, abort — we'd otherwise let the SDK silently install a stale copy.
2. **CUDA version check.** ZED SDK 5.3 requires CUDA 12.6, which is
   what L4T 36.5 ships. Mismatched CUDA → segfault on first `pyzed` import.
3. **Run the `.run` installer in `silent runtime_only skip_python
   skip_cuda skip_tools skip_od_module skip_hub nvpmodel=0`** mode (verified flags — `skip_drivers` does not exist; see [Verification Report]({{ '/VERIFICATION_REPORT' | relative_url }}) §2.3). Userspace libs only; DKMS path skipped.
4. **Install `pyzed`** into `/opt/av-env` (our venv) by running
   `/usr/local/zed/get_python_api.py` with the venv's Python interpreter.
5. **Smoke test** with `python -c "import pyzed.sl"`.

If a future SDK version adds a DKMS rebuild path, our shipped
`linux-headers-*.deb` at `/opt/kernel-headers/` provides headers under
`/usr/src/linux-headers-$(uname -r)/`, so DKMS can build a vermagic-correct
module. The result shadows ours under `/lib/modules/extra/` — harmless but
redundant.

### 2.3 Pre-flight checklist before bake

1. Download `ZED_SDK_Tegra_*.run` for the matching JetPack version
   (5.3 for JetPack 6.2.2). Place in `<repo>/zed-sdk/`.
2. Confirm `make build` produced a `linux-headers-*.deb` under
   `latest_jetson/Linux_for_Tegra/staging/kernel-headers/`.
3. Run `make bake` and confirm:
   ```
   [*] Baking linux-headers .deb (vermagic-aligned)...
      -> linux-headers-...deb baked into /opt/kernel-headers/
   [*] Baking ZED SDK installer + wrapper...
      -> ZED_SDK_Tegra_..._5.3.run staged at /opt/zed-sdk/
   ```

### 2.4 Post-flash verification

```bash
# Headers installed
ls /usr/src/linux-headers-$(uname -r)/Makefile

# ZED SDK userspace in place
test -f /usr/local/zed/include/sl/Camera.hpp && echo OK

# pyzed importable from venv
/opt/av-env/bin/python -c "import pyzed.sl as sl; print(sl.__file__)"
```

---

## 3. Axelera Metis (Voyager SDK)

The Voyager SDK ships **two independent things**: a kernel module
(`metis.ko`) and Python tooling (`axelera-rt`, `axelera-devkit`). We
separate their concerns to neutralize the vermagic trap.

### 3.1 Kernel-side: Metis is in-tree

Promoted to **in-tree** under `drivers/misc/axelera/` by Phase 1. The
vendor source remains canonical at `source/axelera/axelera-driver/`; the
in-tree directory is a thin Kconfig + Kbuild shim that symlinks back to
it. Defconfig flag: `CONFIG_AXELERA_METIS=m`.

Result: `metis.ko` is built by the kernel's own `make modules`, with the
exact same vermagic, GCC, and `Module.symvers` CRCs as the kernel image.
No DKMS, no surprise mismatches.

See [`KERNEL_PATCHES.md`](KERNEL_PATCHES.md) §6 and
[`VERMAGIC_STRATEGY.md`](VERMAGIC_STRATEGY.md).

### 3.2 The PCIe patience patch

The Axelera Metis is invisible to `lspci` on cold boot with NVIDIA's
default PCIe link-training timeout (10 retries). Phase 1 forces:

```c
// drivers/pci/controller/dwc/pcie-designware.h
#define LINK_WAIT_MAX_RETRIES   100
```

Applies `voyager-sdk/axl-jetson.patch`, then `sed`-forces 100 regardless.
Without this patch, the M.2 slot reports nothing.

See [`KERNEL_PATCHES.md`](KERNEL_PATCHES.md) §1.

### 3.3 Userspace: pip wheels, not install.sh --driver

Voyager SDK 1.6 changed install method. The legacy `install.sh --driver
--runtime --common` is no longer required (or recommended) because:

1. The driver path is dead — the kernel already has `metis.ko` baked in.
2. The runtime + tooling are now distributed as pip wheels at
   `https://software.axelera.ai/artifactory/axelera-pypi/`.

`scripts/jetson_first_boot.sh` installs them into `/opt/av-env`:

```bash
pip install axelera-rt axelera-devkit \
    --extra-index-url https://software.axelera.ai/artifactory/api/pypi/axelera-pypi/simple
```

Hard requirement: `numpy<2.0.0` (Voyager rejects numpy 2.x).

### 3.4 Environment glue

`AXELERA_GST_EXPLICIT_PARSE=1` is appended to `/opt/av-env/bin/activate`.
GStreamer pipelines feeding Metis must operate in explicit-format mode
(no auto-negotiation), or the inference frame format mismatches what the
NPU expects.

### 3.5 udev rules

`72-axelera.rules` is staged into the rootfs by Phase 1
(`scripts/01_extract_and_patch.sh`). It names the Metis PCIe device node
predictably so the runtime can find it without scanning all of `/dev/pci*`.

### 3.6 Verification on target

```bash
# Kernel module: in-tree, vermagic-aligned
lsmod | grep metis
modinfo metis | grep vermagic   # must contain $(uname -r)

# PCIe link (vendor:device 1f9d:1100 — Axelera AI Metis AIPU)
lspci | grep -i axelera
sudo lspci -vvv -d 1f9d: | grep LnkSta   # Metis M.2 = M.2 2280, PCIe Gen3 x4
                                          # → expect "Speed 8GT/s, Width x4"

# Voyager runtime in venv
/opt/av-env/bin/python -c "import axelera.runtime; print(axelera.runtime.__version__)"

# DMABUF heap exposed
ls /dev/dma_heap/   # system, linux,cma
```

---

## 4. Compatibility matrix (must agree across all three)

| Component  | This build         | Why locked                             |
|-----------|--------------------|----------------------------------------|
| L4T       | R36.5.0            | JetPack 6.2.2 baseline                 |
| CUDA      | 12.6               | Locked to L4T; do not pip-install      |
| ZED SDK   | 5.3.x              | Requires CUDA 12.6                     |
| pyzed     | matches SDK 5.3    | Installed via `get_python_api.py`      |
| numpy     | <2.0.0             | Hard requirement of Voyager SDK 1.6    |
| sl_zedx.ko| in-tree, our build | Vermagic-aligned with kernel           |
| metis.ko  | in-tree, our build | Vermagic-aligned with kernel           |

Mixing versions across this matrix breaks runtime in non-obvious ways
(silent frame corruption, segfaults at import, init failures with no log).
Run `make versions` to print the manifest at any time.

---

## 5. Troubleshooting

### `lsmod | grep sl_zedx` empty but module is on disk

Vermagic mismatch. Run `sudo /home/j/verify_tuning.sh`, fix per
[`VERMAGIC_STRATEGY.md`](VERMAGIC_STRATEGY.md).

### `v4l2-ctl --list-devices` shows nothing for ZED X

Overlay didn't apply. Verify `OVERLAYS` line in
`/boot/extlinux/extlinux.conf` and that the `.dtbo` file exists in
`/boot/`.

### Frames present but visually wrong

ISP `.isp` calibration missing or for the wrong sensor. Check
`/var/nvidia/nvcam/settings/`.

### `dmesg` shows MAX96712 errors

Wrong deserializer slipped through. Re-run Phase 1 (verify both the
defconfig flag and the Makefile `-D` flag).

### `lspci` shows nothing for Axelera

PCIe link train failed; LINK_WAIT_MAX_RETRIES patch may not have applied.
Verify `pcie-designware.h` shows `100`, rebuild and re-flash.

### `lsmod | grep metis` empty but `modinfo` works

modprobe failed. Most often vermagic mismatch. Run
`sudo /home/j/verify_tuning.sh` and look at the Module Vermagic Sanity
section.

### Voyager runtime fails with OOM / dropped inferences

`jetson_rt_tune.sh` shields the Axelera runtime with `oom_score_adj=-1000`,
but only after the process is running. If OOM strikes during launch,
shrink the model or close other processes.

### ZED SDK install fails to build sl_zedx.ko

`linux-headers-*.deb` wasn't installed before the SDK installer ran.
`dpkg -i /opt/kernel-headers/linux-headers-*.deb`, then re-run
`/opt/zed-sdk/install_zed_sdk.sh`. If the .deb is missing entirely,
re-run Phase 2 (`make build`) and re-bake (`make bake`).

For the symptom-first failure-mode table see
[`TROUBLESHOOTING.md`](TROUBLESHOOTING.md).
