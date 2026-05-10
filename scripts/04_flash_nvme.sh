#!/bin/bash
set -e

# Source versions.env to pick up TARGET_BOARD / TARGET_STORAGE_DEV. Defaults
# below match the original hardcoded values, so the script behaves the same
# if config.sh / versions.env are missing.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/config.sh" 2>/dev/null || true

# Fall back to original literals if versions.env didn't define these.
TARGET_BOARD="${TARGET_BOARD:-jetson-orin-nano-devkit-super}"
TARGET_STORAGE_DEV="${TARGET_STORAGE_DEV:-nvme0n1p1}"
TARGET_FLASH_XML="${TARGET_FLASH_XML:-tools/kernel_flash/flash_l4t_t234_nvme.xml}"
TARGET_QSPI_XML="${TARGET_QSPI_XML:-bootloader/generic/cfg/flash_t234_qspi.xml}"

echo "==========================================="
echo " AV Kernel Phase 4: NVMe Flashing"
echo "==========================================="
echo " Board     : $TARGET_BOARD"
echo " Storage   : $TARGET_STORAGE_DEV"
echo " Flash XML : $TARGET_FLASH_XML"
echo " QSPI  XML : $TARGET_QSPI_XML"
echo "==========================================="

cd "$L4T_DIR"

echo "[*] Fusing NVIDIA binaries into rootfs..."
sudo ./tools/l4t_flash_prerequisites.sh
sudo ./apply_binaries.sh

echo "--------------------------------------------------------"
echo " WARNING: The Jetson must be connected via USB and in "
echo " Force Recovery Mode (short REC and GND pins)."
echo " This operation will ERASE the NVMe SSD."
echo "--------------------------------------------------------"

# Auto-detect APX (USB ID 0955:7323) — poll for 60s. Falls back to interactive
# prompt if not found. Set APX_TIMEOUT=0 to skip auto-detect entirely.
APX_TIMEOUT="${APX_TIMEOUT:-60}"
if [ "$APX_TIMEOUT" -gt 0 ]; then
    echo "[*] Polling for APX device (USB ID 0955:7323) for ${APX_TIMEOUT}s..."
    i=0
    while [ "$i" -lt "$APX_TIMEOUT" ]; do
        if lsusb 2>/dev/null | grep -q "0955:7323"; then
            echo "[*] APX detected — proceeding."
            break
        fi
        sleep 1; i=$((i+1))
        printf '.'
    done
    echo
    if ! lsusb 2>/dev/null | grep -q "0955:7323"; then
        echo "[!] APX not detected after ${APX_TIMEOUT}s."
        read -p "    Press ENTER to continue anyway, or Ctrl+C to abort... "
    fi
else
    read -p "Press ENTER to continue when Jetson is in Recovery Mode, or Ctrl+C to abort... "
fi

# The NVIDIA RNDIS flash gadget can appear as eth0 or usb0 depending on
# host udev config. Force it to usb0 so the flash tool finds it.
if [ ! -f /etc/udev/rules.d/72-nvidia-rndis.rules ]; then
    echo "[*] Installing udev rule to name NVIDIA RNDIS gadget as usb0..."
    sudo tee /etc/udev/rules.d/72-nvidia-rndis.rules > /dev/null <<'UDEV'
# NVIDIA Tegra initrd flash RNDIS gadget → always usb0
SUBSYSTEM=="net", ACTION=="add", ATTRS{idVendor}=="0955", ATTRS{idProduct}=="7035", NAME="usb0"
UDEV
    sudo udevadm control --reload-rules
fi

# Validate the chosen board exists in this L4T tree before invoking the flash.
# The flasher's error if the board name is wrong is buried 200 lines into the
# log and looks like a generic NVIDIA failure, which has cost real teams
# real time. Catch it here.
if [ -d "$L4T_DIR" ]; then
    cd "$L4T_DIR"
    if ! ls "${TARGET_BOARD}.conf" >/dev/null 2>&1 \
       && ! ls "p3768"*"${TARGET_BOARD}"*.conf >/dev/null 2>&1 \
       && ! ls "${TARGET_BOARD}"*.conf >/dev/null 2>&1; then
        echo "[!] WARNING: no board config matches '$TARGET_BOARD' in $(pwd)"
        echo "    Available board configs:"
        ls -1 *.conf 2>/dev/null | grep -E '^p3768|^jetson-' | sed 's/^/      /' | head -20
        echo "    Set TARGET_BOARD in versions.env to one of the above."
        read -p "Press ENTER to attempt the flash anyway, or Ctrl+C to abort... "
    fi
fi

echo "[*] Initiating Flash Sequence..."
sudo ./tools/kernel_flash/l4t_initrd_flash.sh \
    --external-device "$TARGET_STORAGE_DEV" \
    -c "$TARGET_FLASH_XML" \
    -p "-c $TARGET_QSPI_XML" \
    --showlogs --network usb0 \
    "$TARGET_BOARD" internal

echo "==========================================="
echo " Phase 4 Complete. Flash Successful."
echo "==========================================="
