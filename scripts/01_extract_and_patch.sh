#!/bin/bash
set -e

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/config.sh"
. "$HERE/lib/log.sh"
. "$HERE/lib/plugin.sh"

echo "==========================================="
echo " AV Kernel Phase 1: Extraction & Patching"
echo "==========================================="

mkdir -p "$BUILD_WORKSPACE"
cd "$BUILD_WORKSPACE"

# =============================================================================
# L4T BSP
# =============================================================================
if [ ! -d "Linux_for_Tegra" ]; then
    echo "[*] Extracting L4T Driver Package..."
    tar xf "$TARBALL_L4T_PATH"
else
    echo "[-] Linux_for_Tegra already exists, skipping L4T extraction."
fi

# =============================================================================
# RootFS
# =============================================================================
if [ ! -d "Linux_for_Tegra/rootfs/bin" ]; then
    echo "[*] Populating root filesystem (requires sudo)..."
    if sudo -n true 2>/dev/null; then
        sudo tar xpf "$TARBALL_ROOTFS_PATH" -C Linux_for_Tegra/rootfs/
    else
        echo ""
        echo "[!] ============================================================"
        echo "[!] MANUAL STEP REQUIRED — sudo unavailable for automation."
        echo "[!] Run this command, then re-run make extract:"
        echo "[!]"
        echo "[!]   sudo tar xpf $TARBALL_ROOTFS_PATH \\"
        echo "[!]       -C $BUILD_WORKSPACE/Linux_for_Tegra/rootfs/"
        echo "[!] ============================================================"
        echo ""
        exit 1
    fi
else
    echo "[-] rootfs already populated, skipping."
fi

# =============================================================================
# Public Sources
# =============================================================================
sudo chown -R "$(id -u):$(id -g)" Linux_for_Tegra/source || true

if [ ! -d "Linux_for_Tegra/source/kernel/kernel-jammy-src" ]; then
    echo "[*] Extracting public sources..."
    tar xf "$TARBALL_PUBLIC_SOURCES_PATH" -C .
    cd Linux_for_Tegra/source
    tar xf kernel_src.tbz2
    tar xf kernel_oot_modules_src.tbz2
    tar xf nvidia_kernel_display_driver_source.tbz2
    cd ../..
else
    echo "[-] Sources already extracted, skipping."
fi

# =============================================================================
# Plugin hooks — vendor source injection (ZED X, Axelera, custom)
# Each plugin checks its own CONFIG_ guards internally.
# =============================================================================
load_plugins
run_hook post_extract

# =============================================================================
# Core AV kernel defconfig injection
# Vendor-specific CONFIG_ symbols are appended by plugin post_defconfig hooks.
# =============================================================================
DEFCONFIG="Linux_for_Tegra/source/kernel/kernel-jammy-src/arch/arm64/configs/defconfig"

if ! grep -q "CONFIG_PREEMPT_RT=y" "$DEFCONFIG" && \
   ! grep -q "# AV KERNEL" "$DEFCONFIG"; then
    echo "[*] Injecting AV kernel configuration..."

    # --- Preemption model ---
    PREEMPT_RT_BLOCK=""
    if [ "${CONFIG_KERNEL_PREEMPT_RT:-y}" = "y" ]; then
        PREEMPT_RT_BLOCK="CONFIG_PREEMPT_RT=y"
    elif [ "${CONFIG_KERNEL_PREEMPT_DYNAMIC:-n}" = "y" ]; then
        PREEMPT_RT_BLOCK="CONFIG_PREEMPT_DYNAMIC=y"
    fi
    # (stock PREEMPT is the kernel default — no explicit injection needed)

    # --- CPU isolation (only with RT) ---
    LOW_JITTER_BLOCK=""
    if [ "${CONFIG_LOW_JITTER:-y}" = "y" ] && [ "${CONFIG_KERNEL_PREEMPT_RT:-y}" = "y" ]; then
        LOW_JITTER_BLOCK="CONFIG_NO_HZ_FULL=y
CONFIG_CPU_ISOLATION=y
CONFIG_RCU_NOCB_CPU=y
CONFIG_IRQ_FORCED_THREADING=y"
    fi

    # --- CMA size ---
    CMA_MBYTES="${CONFIG_CMA_SIZE_MBYTES:-2048}"

    cat >> "$DEFCONFIG" <<EOF

# =============================================================
# AV KERNEL: Real-Time Core
# =============================================================
${PREEMPT_RT_BLOCK}
${LOW_JITTER_BLOCK}
CONFIG_HZ_1000=y
# CONFIG_HZ_250 is not set
CONFIG_CPU_FREQ_DEFAULT_GOV_PERFORMANCE=y
# CONFIG_CPU_FREQ_DEFAULT_GOV_SCHEDUTIL is not set

# =============================================================
# AV KERNEL: CMA — contiguous memory for 4K stereo AI buffers
# Also set cma=NM in extlinux.conf boot args (belt+suspenders)
# =============================================================
CONFIG_CMA_SIZE_MBYTES=${CMA_MBYTES}

# =============================================================
# AV KERNEL: HugePages for AI/Vision buffer performance
# =============================================================
CONFIG_HUGETLB_PAGE=y

# =============================================================
# AV KERNEL: Armv8.5-A silicon features
# =============================================================
CONFIG_ARM64_PTR_AUTH=y
CONFIG_ARM64_BTI=y
CONFIG_ARM64_BTI_KERNEL=y
CONFIG_CRYPTO_AES_ARM64_CE=y
CONFIG_CRYPTO_SHA512_ARM64=y
CONFIG_KERNEL_MODE_NEON=y

# =============================================================
# AV KERNEL: Aerospace hardening & resiliency
# =============================================================
CONFIG_EDAC=y
CONFIG_EDAC_TEGRA=y
CONFIG_PSTORE=y
CONFIG_PSTORE_RAM=y
CONFIG_SOFT_WATCHDOG=y
CONFIG_HARDLOCKUP_DETECTOR=y

# =============================================================
# AV KERNEL: Network — ROS 2 DDS multicast + low-latency QoS
# =============================================================
CONFIG_NET_SCH_FQ=m
CONFIG_NET_SCH_FQ_CODEL=m

# =============================================================
# AV KERNEL: Wi-Fi — Realtek RTL8822CE (M.2 Key E)
# =============================================================
CONFIG_RTW88=m
CONFIG_RTW88_8822CE=m

# =============================================================
# AV KERNEL: PCIe always-on (Axelera sub-microsecond wake)
# =============================================================
# CONFIG_PCIEASPM is not set

# =============================================================
# AV KERNEL: PCIe Advanced Error Reporting (AER)
# =============================================================
CONFIG_PCIEPORTBUS=y
CONFIG_PCIEAER=y
CONFIG_PCIE_DPC=y
CONFIG_PCIEAER_INJECT=m

# =============================================================
# AV KERNEL: Strip debug overhead — no jitter sources
# =============================================================
# CONFIG_KASAN is not set
# CONFIG_PROVE_LOCKING is not set
# CONFIG_DEBUG_LOCKDEP is not set
# CONFIG_SLUB_DEBUG is not set
# CONFIG_KMEMLEAK is not set
# CONFIG_FUNCTION_GRAPH_TRACER is not set
# CONFIG_DYNAMIC_FTRACE is not set
# CONFIG_SCHED_DEBUG is not set

# =============================================================
# AV KERNEL: Filesystem extras
# =============================================================
CONFIG_FUSE_FS=m
CONFIG_VFAT_FS=m
CONFIG_NTFS_FS=m

# =============================================================
# AV KERNEL: RT depth — high-res timers, RCU boost
# =============================================================
CONFIG_HIGH_RES_TIMERS=y
CONFIG_HZ=1000
CONFIG_RCU_BOOST=y
CONFIG_RCU_BOOST_DELAY=500
# CONFIG_PREEMPT_DYNAMIC is not set
# CONFIG_NO_HZ_IDLE is not set
# CONFIG_NUMA_BALANCING is not set
# CONFIG_SCHED_AUTOGROUP is not set
# CONFIG_LATENCYTOP is not set

# =============================================================
# AV KERNEL: Memory & cache for AI buffers
# =============================================================
CONFIG_TRANSPARENT_HUGEPAGE=y
CONFIG_TRANSPARENT_HUGEPAGE_MADVISE=y
CONFIG_USERFAULTFD=y
CONFIG_PAGE_REPORTING=y
# CONFIG_ZSWAP is not set
# CONFIG_ZRAM is not set

# =============================================================
# AV KERNEL: cgroups v2 — core/memory partitioning
# =============================================================
CONFIG_CGROUPS=y
CONFIG_CGROUP_SCHED=y
CONFIG_CGROUP_CPUACCT=y
CONFIG_CPUSETS=y
CONFIG_CGROUP_DEVICE=y
CONFIG_CGROUP_FREEZER=y
CONFIG_CGROUP_PIDS=y
CONFIG_CGROUP_BPF=y
CONFIG_MEMCG=y
CONFIG_MEMCG_SWAP=y

# =============================================================
# AV KERNEL: Networking — ROS 2 DDS, MAVROS, BBR
# =============================================================
CONFIG_TCP_CONG_BBR=m
CONFIG_DEFAULT_TCP_CONG="bbr"
CONFIG_NET_FOU=m
CONFIG_BPF_JIT=y
CONFIG_BPF_JIT_ALWAYS_ON=y
CONFIG_XDP_SOCKETS=y
CONFIG_NET_RX_BUSY_POLL=y

# =============================================================
# AV KERNEL: I/O — NVMe, async I/O, USB-serial for FCU + modems
# =============================================================
CONFIG_BLK_MQ_PCI=y
CONFIG_NVME_MULTIPATH=y
CONFIG_NVME_HWMON=y
CONFIG_IO_URING=y
CONFIG_USB_ANNOUNCE_NEW_DEVICES=y
CONFIG_USB_SERIAL_FTDI_SIO=m
CONFIG_USB_SERIAL_CP210X=m
CONFIG_USB_ACM=m
CONFIG_USB_USBNET=m
CONFIG_USB_NET_RNDIS_HOST=m
CONFIG_USB_NET_CDCETHER=m

# =============================================================
# AV KERNEL: Security & hardening
# =============================================================
CONFIG_HARDENED_USERCOPY=y
CONFIG_FORTIFY_SOURCE=y
CONFIG_STACKPROTECTOR_STRONG=y
CONFIG_RANDOMIZE_BASE=y
CONFIG_RANDOMIZE_MODULE_REGION_FULL=y
CONFIG_INIT_STACK_ALL_ZERO=y
# CONFIG_DEVMEM is not set
# CONFIG_LEGACY_PTYS is not set

# =============================================================
# AV KERNEL: Module discipline — vermagic + symbol CRC enforcement
# =============================================================
CONFIG_MODVERSIONS=y
CONFIG_MODULE_SRCVERSION_ALL=y
# CONFIG_MODULE_FORCE_LOAD is not set

# =============================================================
# AV KERNEL: Platform resilience — kdump, LSM, TPM
# =============================================================
CONFIG_KEXEC=y
CONFIG_KEXEC_FILE=y
CONFIG_CRASH_DUMP=y
CONFIG_PROC_VMCORE=y
CONFIG_SECURITY=y
CONFIG_SECURITY_YAMA=y
CONFIG_SECURITY_LOCKDOWN_LSM=y
CONFIG_LSM="yama,lockdown,integrity"
CONFIG_TCG_TPM=y
CONFIG_TCG_TIS=y
CONFIG_HW_RANDOM_TPM=y

# =============================================================
# AV KERNEL: Strip remaining debug overhead
# =============================================================
# CONFIG_FUNCTION_TRACER is not set
# CONFIG_DEBUG_PREEMPT is not set
# CONFIG_DEBUG_RT_MUTEXES is not set
# CONFIG_PROVE_RCU is not set
# CONFIG_TIMER_STATS is not set
# CONFIG_DEBUG_VM is not set
# CONFIG_DEBUG_BUGVERBOSE is not set
EOF
    echo "   -> AV kernel config injected."
else
    # Fix CMA even if block already present
    if grep -q "CONFIG_CMA_SIZE_MBYTES=32" "$DEFCONFIG"; then
        local CMA_MBYTES="${CONFIG_CMA_SIZE_MBYTES:-2048}"
        sed -i "s/CONFIG_CMA_SIZE_MBYTES=32/CONFIG_CMA_SIZE_MBYTES=${CMA_MBYTES}/" "$DEFCONFIG"
        echo "[*] Fixed CMA_SIZE_MBYTES: 32 → ${CMA_MBYTES} MB."
    fi
    echo "[-] AV kernel config already present."
fi

# =============================================================================
# Plugin hooks — vendor CONFIG_ additions
# (ZED X deserializer, DMABUF symbols, CONFIG_AXELERA_METIS, etc.)
# =============================================================================
run_hook post_defconfig

# =============================================================================
# Enable PREEMPT_RT via NVIDIA's script (conditional on config)
# =============================================================================
if [ "${CONFIG_KERNEL_PREEMPT_RT:-y}" = "y" ]; then
    echo "[*] Enabling PREEMPT_RT via NVIDIA generic_rt_build.sh..."
    cd Linux_for_Tegra/source
    ./generic_rt_build.sh "enable"
    cd ../..
else
    echo "[*] Skipping PREEMPT_RT (CONFIG_KERNEL_PREEMPT_RT not set)"
fi

echo ""
echo "==========================================="
echo " Phase 1 Complete. Ready for Compilation."
echo "==========================================="
echo ""
echo " Next: make docker-build  (one-time, if not done)"
echo "       make build          (runs inside Docker)"
