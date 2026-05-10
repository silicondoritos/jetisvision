---
title: Configuration
layout: default
description: "kconfiglib-based build configuration system: menuconfig TUI, defconfig profiles, plugin system for vendor trees."
nav_order: 6
---

# Configuration

The build uses [kconfiglib](https://github.com/ulfalizer/Kconfiglib) — the Python reimplementation of the Linux kernel's Kconfig system — to manage build options. The same `menuconfig` TUI familiar from kernel builds, applied to the firmware stack.

## Quick start

```bash
pip install kconfiglib          # one-time, on host

make defconfig                  # apply committed defaults
make menuconfig                 # interactive TUI — change options, save
make savedefconfig              # write .config back to defconfig (commit this)
```

Then build normally:

```bash
make all
```

## How it works

`make menuconfig` writes `.config` to the repo root. Every script sources `scripts/lib/config.sh`, which loads `versions.env` (version pins) then `.config` (feature flags). Both are then available as shell variables:

```bash
# In any script, after sourcing config.sh:
if [ "${CONFIG_AXELERA_METIS:-y}" = "y" ]; then
    # Axelera integration enabled
fi
```

`.config` is gitignored — it is user-specific. The committed file is `defconfig`, which is the minimal diff from Kconfig defaults. Share build profiles by sharing `defconfig` files.

## Options

### Kernel

| Option | Default | Notes |
|---|---|---|
| `CONFIG_KERNEL_PREEMPT_RT` | y | Full PREEMPT_RT. Required for sub-100µs jitter. |
| `CONFIG_LOW_JITTER` | y | NO_HZ_FULL + isolcpus + RCU NOCB. Depends on PREEMPT_RT. |
| `CONFIG_ISOLATED_CORE_RANGE` | `"1-5"` | Injected into extlinux.conf boot args. |
| `CONFIG_CMA_SIZE_MBYTES` | 2048 | Contiguous memory. 2048 required for 4K stereo pipeline. |

### Camera

| Option | Default | Notes |
|---|---|---|
| `CONFIG_CAMERA_ZEDX_MONO` | y | ZED Link Mono, MAX9296 deserializer. Requires `zedx-driver`. |
| `CONFIG_CAMERA_ZEDX_DUO` | n | ZED Link Duo, MAX96712 deserializer. Requires `zedx-driver`. |
| `CONFIG_CAMERA_NONE` | n | No camera. Disables all ZED X plugin hooks. |
| `CONFIG_DMABUF_ZEROCOPY` | y | Zero-copy pipeline. Requires a ZED X camera option. |

### AI Accelerator

| Option | Default | Notes |
|---|---|---|
| `CONFIG_AXELERA_METIS` | y | Axelera Metis M.2. Requires `axelera-driver`. |
| `CONFIG_METIS_POWER_CAP_W` | 18 | Brownout guard cap. Datasheet peak ~23W. |
| `CONFIG_PCIE_LINK_WAIT_MAX_RETRIES` | 100 | PCIe cold-boot patience. Stock L4T is 10. |
| `CONFIG_VOYAGER_SDK` | y | Stage Voyager SDK into rootfs. Requires `voyager-sdk`. |

### Power

| Option | Default | Notes |
|---|---|---|
| `CONFIG_NVPMODEL_MAXN_SUPER` | y | mode 4, 40W / 157 TOPS. Validate HV rail first (§3.6). |
| `CONFIG_NVPMODEL_MAXN` | n | mode 0, 25W. Safe on any P3509-class carrier. |
| `CONFIG_NVPMODEL_15W` / `10W` | n | Reduced power modes. |

### Application Stack

| Option | Default | Notes |
|---|---|---|
| `CONFIG_ISAAC_ROS_SOURCE` | y | Build Isaac ROS from source. ~45 min per device. |
| `CONFIG_ISAAC_ROS_APT` | n | APT binary packages. Run field-confirm §3.4 first. |
| `CONFIG_ISAAC_ROS_NONE` | n | Skip Isaac ROS entirely. |

### Flight Controller

| Option | Default | Notes |
|---|---|---|
| `CONFIG_FCU_MAVROS` | y | Enable MAVLink / MAVROS integration. |
| `CONFIG_FCU_TTY` | `/dev/ttyTHS1` | Serial port. Do NOT use `/dev/ttyTHS0` (debug console). |
| `CONFIG_FCU_BAUD` | 921600 | Must match Pixhawk TELEM2 baud rate. |

## Named profiles

Save a profile with `make savedefconfig` and commit `defconfig`. To ship multiple profiles:

```bash
cp defconfig defconfigs/layer1-only.defconfig     # no camera, no ROS
cp defconfig defconfigs/full-stack.defconfig      # everything
```

Load a profile:

```bash
make defconfig KCONFIG_ALLCONFIG=defconfigs/layer1-only.defconfig
```

Or just copy a defconfig file to `defconfig` before running `make defconfig`.

## Building without camera (Layer 1 only)

```bash
make menuconfig
# set Camera → CAMERA_NONE
# set AI Accelerator → keep AXELERA_METIS=y
make savedefconfig
make all
```

`make doctor` will not require `zedx-driver` or `zed-sdk` when `CAMERA_NONE=y`.

## Building without Axelera

```bash
make menuconfig
# disable AI Accelerator → AXELERA_METIS
make savedefconfig
make all
```

`make doctor` will not require `axelera-driver` or `voyager-sdk`.

## Plugin system

Each hardware integration (ZED X, Axelera) is a plugin in `plugins/<name>/`:

```
plugins/
  zedx/
    Kconfig      additional config options for ZED X
    plugin.sh    hook functions: doctor, post_extract, post_defconfig, pre_bake, post_bake
  axelera/
    Kconfig      additional config options for Axelera
    plugin.sh    hook functions: doctor, post_extract, post_defconfig, pre_bake
```

Plugins contain integration glue only — the vendor source trees are external (gitignored). Each plugin checks its own `CONFIG_` flags internally and is a no-op if the relevant feature is disabled.

### Custom plugin

To add support for additional hardware:

1. Create a directory anywhere with a `plugin.sh`:

```bash
mkdir -p /path/to/my-plugin
cat > /path/to/my-plugin/plugin.sh <<'EOF'
plugin_name() { echo "myhardware"; }

myhardware_doctor() {
    [ -d "/path/to/vendor/tree" ] || { echo "vendor tree missing"; return 1; }
}

myhardware_post_extract() {
    # inject sources, apply patches
}

myhardware_post_defconfig() {
    # append CONFIG_* to kernel defconfig
}

myhardware_pre_bake() {
    # stage files into $L4T_DIR/rootfs
}
EOF
```

2. Register in `.config`:

```
CONFIG_PLUGIN_CUSTOM_PATH="/path/to/my-plugin"
```

Or via `make menuconfig` → Plugins → Custom plugin directory path.

### Hook phases

| Hook | When called | Typical use |
|---|---|---|
| `doctor` | `make doctor` | validate prerequisites, give acquisition instructions |
| `post_extract` | after L4T extraction | inject vendor sources, apply patches, create in-tree shims |
| `post_defconfig` | after core CONFIG_ injection | append vendor-specific CONFIG_* symbols |
| `pre_bake` | before rootfs bake | stage calibration files, SDK installers, udev rules |
| `post_bake` | after rootfs bake | inject DTBO overlay into extlinux.conf |

All hooks are optional. Missing hooks are silently skipped.
