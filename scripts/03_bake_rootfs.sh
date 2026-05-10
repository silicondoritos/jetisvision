#!/bin/bash
set -e

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/config.sh"
. "$HERE/lib/log.sh"
. "$HERE/lib/plugin.sh"

echo "==========================================="
echo " AV Kernel Phase 3: Payload Baking"
echo "==========================================="

ROOTFS="$L4T_DIR/rootfs"
L4T="$L4T_DIR"
TARGET_HOME="$ROOTFS/home/${TARGET_USER:-j}"
SCRIPTS="$REPO_ROOT/scripts"

echo "[*] Creating target home directory..."
sudo mkdir -p "$TARGET_HOME"
sudo chown 1000:1000 "$TARGET_HOME" || true

# =============================================================================
# Linux headers .deb — required for on-target DKMS rebuilds
# The ZED SDK installer and Voyager install.sh both build kernel modules via
# DKMS and look for headers under /usr/src/linux-headers-$(uname -r)/.
# We ship a .deb that extracts to exactly that path, dpkg-installed at
# first-boot before any third-party installer runs.
# =============================================================================
echo "[*] Baking linux-headers .deb (vermagic-aligned)..."
sudo mkdir -p "$ROOTFS/opt/kernel-headers"
if [ -d "$HEADERS_STAGING" ] && ls "$HEADERS_STAGING"/linux-headers-*.deb >/dev/null 2>&1; then
    sudo cp "$HEADERS_STAGING"/linux-headers-*.deb "$ROOTFS/opt/kernel-headers/"
    echo "   -> $(ls "$HEADERS_STAGING" | head -1) baked into /opt/kernel-headers/"
else
    echo "   [WARN] No headers .deb found at $HEADERS_STAGING — DKMS modules"
    echo "          (ZED SDK, Voyager driver) will fail to build on target."
    echo "          Re-run 'make build' to produce the .deb."
fi

# =============================================================================
# Plugin hooks — vendor tree staging (ZED X ISP + SDK, Axelera Voyager + udev)
# Each plugin checks its own CONFIG_ guards internally.
# =============================================================================
load_plugins
run_hook pre_bake

# =============================================================================
# Per-device personalization + CLI tools
# =============================================================================
echo "[*] Baking personalize_first_boot.sh..."
sudo cp "$SCRIPTS/personalize_first_boot.sh" "$TARGET_HOME/personalize_first_boot.sh"
sudo chmod +x "$TARGET_HOME/personalize_first_boot.sh"

echo "[*] Baking jetson-av-version CLI..."
sudo install -m 0755 "$SCRIPTS/jetson-av-version" "$ROOTFS/usr/local/bin/jetson-av-version"

# =============================================================================
# Build manifest — on-device provenance (/etc/jetson-av-build.json)
# =============================================================================
echo "[*] Baking BUILD_MANIFEST.json → /etc/jetson-av-build.json..."
if [ -f "$L4T/BUILD_MANIFEST.json" ]; then
    sudo install -m 0644 "$L4T/BUILD_MANIFEST.json" "$ROOTFS/etc/jetson-av-build.json"
    echo "   -> $(jq -r .kernel_release < "$L4T/BUILD_MANIFEST.json" 2>/dev/null \
              || grep -oE '"kernel_release": *"[^"]*"' "$L4T/BUILD_MANIFEST.json")"
else
    echo "   [WARN] BUILD_MANIFEST.json missing — re-run 'make build'."
fi

# =============================================================================
# First-boot and per-boot scripts
# =============================================================================
echo "[*] Baking first-boot and RT tuning scripts..."
for f in jetson_first_boot.sh jetson_rt_tune.sh; do
    sudo cp "$SCRIPTS/$f" "$TARGET_HOME/$f"
    sudo chmod +x "$TARGET_HOME/$f"
done

# =============================================================================
# Phase 7: Platform resilience scripts
# =============================================================================
echo "[*] Baking Phase 7 (Platform Hardening) scripts..."
sudo install -m 0755 "$SCRIPTS/axrun" "$ROOTFS/usr/local/bin/axrun"
sudo mkdir -p "$TARGET_HOME/phase7"
for f in install_uav_phase7.sh install_uav_resilience.sh \
         install_blackbox.sh jetson_blackbox.sh \
         axelera_brownout_guard.sh mavlink_watchdog.sh \
         jetson_pcie_aer_monitor.sh \
         install_data_partition.sh install_telemetry_failover.sh; do
    if [ -f "$SCRIPTS/$f" ]; then
        sudo cp "$SCRIPTS/$f" "$TARGET_HOME/phase7/$f"
        sudo chmod +x "$TARGET_HOME/phase7/$f"
        echo "   -> phase7/$f"
    fi
done
sudo mkdir -p "$TARGET_HOME/phase7/lib"
sudo cp "$SCRIPTS"/lib/*.sh "$TARGET_HOME/phase7/lib/"

# =============================================================================
# Phase 5: AV application stack scripts
# =============================================================================
echo "[*] Baking Phase 5 (AV stack: OpenCV-CUDA + ROS 2 + Isaac + Nav2 + MAVROS)..."
sudo mkdir -p "$TARGET_HOME/phase5"
for f in install_av_phase5.sh build_opencv_cuda.sh verify_opengl_cuda.sh \
         install_av_stack.sh launch_av_mission.sh; do
    if [ -f "$SCRIPTS/$f" ]; then
        sudo cp "$SCRIPTS/$f" "$TARGET_HOME/phase5/$f"
        sudo chmod +x "$TARGET_HOME/phase5/$f"
        echo "   -> phase5/$f"
    fi
done
sudo mkdir -p "$TARGET_HOME/phase5/lib"
sudo cp "$SCRIPTS"/lib/*.sh "$TARGET_HOME/phase5/lib/"

# =============================================================================
# Verification gauntlet
# =============================================================================
echo "[*] Baking verification gauntlet..."
sudo cp "$SCRIPTS/verify_tuning.sh" "$TARGET_HOME/verify_tuning.sh"
sudo chmod +x "$TARGET_HOME/verify_tuning.sh"

# =============================================================================
# Systemd services
# =============================================================================
echo "[*] Installing systemd services..."
sudo cp "$SCRIPTS/jetson-first-boot.service" "$ROOTFS/etc/systemd/system/"
sudo cp "$SCRIPTS/jetson-rt-tune.service"    "$ROOTFS/etc/systemd/system/"
sudo chmod 644 "$ROOTFS/etc/systemd/system/jetson-first-boot.service"
sudo chmod 644 "$ROOTFS/etc/systemd/system/jetson-rt-tune.service"
sudo mkdir -p "$ROOTFS/etc/systemd/system/multi-user.target.wants/"
sudo ln -sf /etc/systemd/system/jetson-first-boot.service \
    "$ROOTFS/etc/systemd/system/multi-user.target.wants/jetson-first-boot.service"
sudo ln -sf /etc/systemd/system/jetson-rt-tune.service \
    "$ROOTFS/etc/systemd/system/multi-user.target.wants/jetson-rt-tune.service"

# =============================================================================
# Bootloader: RT boot parameters (config-driven)
# =============================================================================
echo "[*] Injecting RT boot parameters..."
EXTLINUX="$ROOTFS/boot/extlinux/extlinux.conf"
if [ -f "$EXTLINUX" ]; then
    # Build boot args string from config
    BOOT_ARGS="efi=noruntime pcie_aspm=off"
    if [ "${CONFIG_LOW_JITTER:-y}" = "y" ] && [ "${CONFIG_KERNEL_PREEMPT_RT:-y}" = "y" ]; then
        CORES="${CONFIG_ISOLATED_CORE_RANGE:-1-5}"
        BOOT_ARGS="nohz_full=${CORES} isolcpus=${CORES} rcu_nocbs=${CORES} irqaffinity=0 ${BOOT_ARGS}"
    fi
    CMA_MB="${CONFIG_CMA_SIZE_MBYTES:-2048}"
    BOOT_ARGS="${BOOT_ARGS} cma=${CMA_MB}M"

    # Remove stale RT args (idempotent re-bake)
    sudo sed -i 's/ nohz_full=[^ ]*//g; s/ isolcpus=[^ ]*//g; s/ rcu_nocbs=[^ ]*//g' "$EXTLINUX"
    sudo sed -i 's/ irqaffinity=[^ ]*//g; s/ efi=noruntime//g; s/ pcie_aspm=off//g' "$EXTLINUX"
    sudo sed -i 's/ cma=[^ ]*//g' "$EXTLINUX"

    # Inject fresh args on active APPEND line
    sudo sed -i "s|^\([[:space:]]*\)APPEND \${cbootargs}|\1APPEND \${cbootargs} ${BOOT_ARGS}|g" "$EXTLINUX"
    echo "   -> boot args: ${BOOT_ARGS}"
else
    echo "   [WARN] extlinux.conf not found in rootfs."
fi

# =============================================================================
# Generate /etc/jetson-av/power.conf from build config
# Baked at image build time so jetson_rt_tune.sh finds it at runtime.
# =============================================================================
echo "[*] Generating /etc/jetson-av/power.conf..."
sudo mkdir -p "$ROOTFS/etc/jetson-av"
if [ "${CONFIG_NVPMODEL_MAXN_SUPER:-y}" = "y" ]; then
    NVPMODEL_MODE_VAL=4
elif [ "${CONFIG_NVPMODEL_MAXN:-n}" = "y" ]; then
    NVPMODEL_MODE_VAL=0
elif [ "${CONFIG_NVPMODEL_15W:-n}" = "y" ]; then
    NVPMODEL_MODE_VAL=1
elif [ "${CONFIG_NVPMODEL_10W:-n}" = "y" ]; then
    NVPMODEL_MODE_VAL=2
else
    NVPMODEL_MODE_VAL=4
fi
printf 'NVPMODEL_MODE=%s\n' "$NVPMODEL_MODE_VAL" | sudo tee "$ROOTFS/etc/jetson-av/power.conf" > /dev/null
printf 'METIS_POWER_CAP_W=%s\n' "${CONFIG_METIS_POWER_CAP_W:-18}" | sudo tee -a "$ROOTFS/etc/jetson-av/power.conf" > /dev/null
echo "   -> NVPMODEL_MODE=$NVPMODEL_MODE_VAL METIS_POWER_CAP_W=${CONFIG_METIS_POWER_CAP_W:-18}"

# =============================================================================
# Plugin hooks — post-bake (ZED X DTBO injection into extlinux.conf)
# =============================================================================
run_hook post_bake

echo ""
echo "==========================================="
echo " Phase 3 Complete. Payload Baked into RootFS."
echo "==========================================="
echo ""
echo " Next (Jetson in Recovery Mode): make flash"
