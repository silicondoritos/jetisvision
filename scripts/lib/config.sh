# =============================================================================
# scripts/lib/config.sh — sourced by every script that needs the pin manifest.
# =============================================================================
# Source this with:
#     . "$(dirname "${BASH_SOURCE[0]}")/lib/config.sh"   # from scripts/
# or:
#     . "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/config.sh"
#
# It loads versions.env into the environment and derives canonical paths.
# Idempotent — safe to re-source.
# =============================================================================

# --- Locate REPO_ROOT in a way that works whether sourced from a script
# living at scripts/, scripts/lib/, or anywhere else under the repo. -----------
__cfg_self="${BASH_SOURCE[0]}"
__cfg_dir="$(cd "$(dirname "$__cfg_self")" && pwd)"
# config.sh sits at scripts/lib/config.sh → REPO_ROOT is two levels up.
REPO_ROOT="$(cd "$__cfg_dir/../.." && pwd)"
export REPO_ROOT

# --- Load versions.env -------------------------------------------------------
VERSIONS_ENV="$REPO_ROOT/versions.env"
if [ -f "$VERSIONS_ENV" ]; then
    # shellcheck disable=SC1090
    set -a
    . "$VERSIONS_ENV"
    set +a
else
    echo "[config.sh] WARN: $VERSIONS_ENV not found — using built-in defaults" >&2
fi

# --- Derived paths (canonical) ------------------------------------------------
# Build workspace: where Phase 1 unpacks L4T. Inside the build container the
# repo is bind-mounted at /home/j/dev/custom_kernel, so this resolves there;
# on the host (when running 03_bake / 04_flash etc.) it resolves to REPO_ROOT.
BUILD_WORKSPACE="${BUILD_WORKSPACE:-$REPO_ROOT/latest_jetson}"
L4T_DIR="$BUILD_WORKSPACE/Linux_for_Tegra"
SOURCE_DIR="$L4T_DIR/source"
KERNEL_SRC="$SOURCE_DIR/kernel/kernel-jammy-src"
ROOTFS="$L4T_DIR/rootfs"
KERNEL_OUT="$L4T_DIR/kernel"
DTB_OUT="$KERNEL_OUT/dtb"
HEADERS_STAGING="$L4T_DIR/staging/kernel-headers"
EXPECTED_VERMAGIC_FILE="$L4T_DIR/EXPECTED_VERMAGIC"
BUILD_MANIFEST="$L4T_DIR/BUILD_MANIFEST.json"

# --- External vendor trees (siblings of REPO_ROOT/* via the .env names) -----
AXELERA_DRIVER_DIR="$REPO_ROOT/$EXTERNAL_AXELERA_DRIVER"
VOYAGER_SDK_DIR="$REPO_ROOT/$EXTERNAL_VOYAGER_SDK"
ZEDX_DRIVER_DIR="$REPO_ROOT/$EXTERNAL_ZEDX_DRIVER"
ZED_SDK_DIR="$REPO_ROOT/$EXTERNAL_ZED_SDK"

# --- Required tarballs (siblings of REPO_ROOT) ------------------------------
TARBALL_L4T_PATH="$REPO_ROOT/$TARBALL_L4T"
TARBALL_ROOTFS_PATH="$REPO_ROOT/$TARBALL_ROOTFS"
TARBALL_PUBLIC_SOURCES_PATH="$REPO_ROOT/$TARBALL_PUBLIC_SOURCES"

# --- Toolchain (in Docker container) ----------------------------------------
TOOLCHAIN_DIR="$TOOLCHAIN_INSTALL_PREFIX/$BOOTLIN_TOOLCHAIN"
CROSS_COMPILE_BIN="$TOOLCHAIN_DIR/bin/$BOOTLIN_PREFIX"

# --- Critical kernel files for audit gates ----------------------------------
PCIE_DESIGNWARE_H="$KERNEL_SRC/drivers/pci/controller/dwc/pcie-designware.h"
DEFCONFIG_PATH="$KERNEL_SRC/arch/arm64/configs/defconfig"
EXTLINUX_CONF="$ROOTFS/boot/extlinux/extlinux.conf"

# --- Critical artifacts -----------------------------------------------------
KERNEL_IMAGE="$KERNEL_OUT/Image"
ZED_DTBO_NAME=tegra234-p3768-camera-zedlink-mono-sl-overlay.dtbo

export BUILD_WORKSPACE L4T_DIR SOURCE_DIR KERNEL_SRC ROOTFS KERNEL_OUT \
       DTB_OUT HEADERS_STAGING EXPECTED_VERMAGIC_FILE BUILD_MANIFEST \
       AXELERA_DRIVER_DIR VOYAGER_SDK_DIR ZEDX_DRIVER_DIR ZED_SDK_DIR \
       TARBALL_L4T_PATH TARBALL_ROOTFS_PATH TARBALL_PUBLIC_SOURCES_PATH \
       TOOLCHAIN_DIR CROSS_COMPILE_BIN \
       PCIE_DESIGNWARE_H DEFCONFIG_PATH EXTLINUX_CONF \
       KERNEL_IMAGE ZED_DTBO_NAME

# --- Load .config (kconfiglib output) ----------------------------------------
# Sourced after versions.env so CONFIG_* vars never shadow version pins.
# Scripts access options as: ${CONFIG_AXELERA_METIS:-y}  (with safe default).
# If .config is absent the build still works — all scripts use fallback defaults
# that match the committed defconfig.
KCONFIG_FILE="$REPO_ROOT/.config"
if [ -f "$KCONFIG_FILE" ]; then
    # Strip comment lines and blank lines before sourcing. .config contains
    # lines like "# CONFIG_FOO is not set" which bash ignores (treated as
    # comments), but also string values like CONFIG_FCU_TTY="/dev/ttyTHS1"
    # that need quoting preserved — the grep passes them through unchanged.
    set -a
    # shellcheck disable=SC1090
    . <(grep -v '^[[:space:]]*#' "$KCONFIG_FILE" | grep -v '^[[:space:]]*$')
    set +a
else
    echo "[config.sh] NOTE: no .config found — run 'make defconfig' or 'make menuconfig'" >&2
fi

export KCONFIG_FILE

# --- Done --------------------------------------------------------------------
JETSON_AV_CONFIG_LOADED=1
export JETSON_AV_CONFIG_LOADED
