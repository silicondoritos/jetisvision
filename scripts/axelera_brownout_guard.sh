#!/bin/bash
# =============================================================================
# scripts/axelera_brownout_guard.sh — keep the Metis NPU within the PSU envelope
# =============================================================================
# The Axelera Metis M.2 can spike to ~20W at peak inference. On an autonomous platform running
# off a battery + DC-DC converter, those spikes can sag the rail enough to
# brownout the Jetson PCIe link → Metis disappears, inference dies, the
# vehicle is suddenly blind.
#
# This service runs at boot, sets a hard power cap on the device via the
# Voyager axdevice CLI, and continuously watches /sys for PCIe link-down
# events. On link-down, it logs an event and tries an axdevice reset.
#
# Configuration: /etc/jetson-av/brownout.conf
#   AXELERA_POWER_LIMIT_W=18
#   PCIE_VENDOR_ID=1d60
#   POLL_INTERVAL=5
# =============================================================================
set -u

CONF=/etc/jetson-av/brownout.conf
POWER_CONF=/etc/jetson-av/power.conf      # unified power budget (Gap 9)
EVENT_PIPE=/var/run/jetson-av-events

# Defaults
AXELERA_POWER_LIMIT_W=18
PCIE_VENDOR_ID=1f9d
PCIE_DEVICE_ID=1100
POLL_INTERVAL=5

# Read the unified power.conf first (single source of truth) then allow
# brownout.conf to override for legacy installs.
# shellcheck disable=SC1090
[ -f "$POWER_CONF" ] && . "$POWER_CONF"
[ -f "$CONF" ]       && . "$CONF"

emit() {
    [ -p "$EVENT_PIPE" ] || return 0
    echo "{\"src\":\"brownout\",\"e\":\"$1\",\"v\":\"$2\"}" > "$EVENT_PIPE" 2>/dev/null || true
}

log() { echo "[brownout] $*"; logger -t jetson-av-brownout "$*" 2>/dev/null || true; }

# --- 1. Apply power cap -----------------------------------------------------
log "Applying Metis power limit: ${AXELERA_POWER_LIMIT_W}W"
if command -v axdevice >/dev/null 2>&1; then
    if axdevice --set-power-limit "$AXELERA_POWER_LIMIT_W" 2>/dev/null; then
        log "Power limit applied"
        emit "power_cap_set" "$AXELERA_POWER_LIMIT_W"
    else
        log "WARN: axdevice power-limit failed (Metis offline?)"
        emit "power_cap_failed" "axdevice"
    fi
else
    log "axdevice not found — Voyager runtime not installed yet"
    emit "axdevice_missing" "1"
fi

# --- 2. Watch loop ----------------------------------------------------------
LAST_STATE="present"
log "Watch loop starting (poll every ${POLL_INTERVAL}s)"
while true; do
    if lspci -d "${PCIE_VENDOR_ID}:" 2>/dev/null | grep -q .; then
        if [ "$LAST_STATE" != "present" ]; then
            log "Metis returned"
            emit "metis_recovered" "1"
        fi
        LAST_STATE="present"
    else
        if [ "$LAST_STATE" != "absent" ]; then
            log "WARN: Metis disappeared from PCIe — possible brownout"
            emit "metis_lost" "1"
            # Try a rescan; sometimes the link recovers without reset.
            echo 1 > /sys/bus/pci/rescan 2>/dev/null || true
            sleep 2
            if lspci -d "${PCIE_VENDOR_ID}:" 2>/dev/null | grep -q .; then
                log "Metis recovered after rescan"
                emit "metis_rescan_ok" "1"
                LAST_STATE="present"
                continue
            fi
        fi
        LAST_STATE="absent"
    fi
    sleep "$POLL_INTERVAL"
done
