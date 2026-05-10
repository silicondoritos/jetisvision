---
title: Field Confirm Results
layout: default
description: "Running log of Phase 8 field-confirm items — LINK_WAIT_MAX_RETRIES, axdevice flags, GStreamer DMABUF property, Isaac ROS apt coverage, ttyTHS1 enumeration, MAXN_SUPER HV rail."
nav_order: 98
---

# Field Confirm Results

Running log of the six Phase 8 field-confirm items. One row per item per hardware unit. Fill in after each procedure is run on the device; once all six are green the "unverified" caveats on the home page and in the Verification Report can be removed.

## Template

| Item | Unit serial | Date | Result | Notes |
|---|---|---|---|---|
| §3.1 LINK_WAIT_MAX_RETRIES | — | — | pending | |
| §3.2 axdevice power flag | — | — | pending | |
| §3.3 AXELERA_GST_EXPLICIT_PARSE | — | — | pending | |
| §3.4 Isaac ROS apt coverage | — | — | pending | |
| §3.5 ttyTHS1 enumeration + MAVROS | — | — | pending | |
| §3.6 HV rail + MAXN_SUPER | — | — | pending | |

## §3.1 — LINK_WAIT_MAX_RETRIES stock value

**Item**: Confirm pre-patch value of `LINK_WAIT_MAX_RETRIES` in the L4T 5.15 kernel tree.

```bash
F=Linux_for_Tegra/source/kernel/kernel-jammy-src/drivers/pci/controller/dwc/pcie-designware.h
grep -n LINK_WAIT_MAX_RETRIES "$F"
```

| Stock value | Action |
|---|---|
| `#define LINK_WAIT_MAX_RETRIES  10` | Mainline default. `sed` to 100 is the intended change. **Pass — keep patch.** |
| `#define LINK_WAIT_MAX_RETRIES  100` | NVIDIA already patched. Our `sed` is idempotent. **Pass — annotate in `KERNEL_PATCHES.md`.** |
| Other value | Document divergence and reconsider 100 vs. NVIDIA's choice. **Action — review.** |

Log: `/var/log/jetson-rt-stack/field-confirm/link-wait-retries-<ts>.log`

<!-- RESULT: -->

## §3.2 — `axdevice` flag spelling

**Item**: Confirm exact flag for setting Metis power limit in Voyager 1.6.

```bash
source /opt/axelera/voyager/venv/bin/activate
axdevice --help 2>&1 | tee /var/log/jetson-rt-stack/field-confirm/axdevice-help-$(date +%s).log
```

Expected: one of `--set-power-limit`, `--power-limit`, `--power-cap`.

**Action**: edit `scripts/axelera_brownout_guard.sh` to use the exact flag observed. If no power-related flag exists, file at https://community.axelera.ai and switch to monitoring `/sys/class/powercap/`.

<!-- RESULT: -->

## §3.3 — `AXELERA_GST_EXPLICIT_PARSE=1`

**Item**: Confirm or remove this env var from `jetson_first_boot.sh` activate-script.

```bash
grep -rn AXELERA_GST_EXPLICIT_PARSE /opt/axelera/voyager 2>/dev/null

unset AXELERA_GST_EXPLICIT_PARSE
gst-launch-1.0 -v <pipeline> 2>&1 | tee /tmp/gst-without.log
export AXELERA_GST_EXPLICIT_PARSE=1
gst-launch-1.0 -v <pipeline> 2>&1 | tee /tmp/gst-with.log
diff /tmp/gst-without.log /tmp/gst-with.log
```

| Result | Action |
|---|---|
| Found in Voyager source with comment | Document in `DRIVERS.md` §2.10; keep. |
| No source mention, no diff in caps | **Remove from `jetson_first_boot.sh`** — stale. |
| No source mention, real caps diff | Open Axelera support ticket with diff; keep with TODO. |

<!-- RESULT: -->

## §3.4 — Isaac ROS Humble apt coverage

**Item**: Confirm whether `ros-humble-isaac-ros-*` apt packages cover what is needed, or whether source build is mandatory.

```bash
sudo apt update
apt-cache search ros-humble-isaac-ros | sort | tee \
    /var/log/jetson-rt-stack/field-confirm/isaac-ros-humble-apt-$(date +%s).log

diff <(apt-cache search ros-humble-isaac-ros | awk '{print $1}' | sort) \
     <(grep -oE 'isaac_ros_[a-z_]+' scripts/install_av_stack.sh | sort -u)
```

| Coverage | Action |
|---|---|
| All required packages in apt | Switch `install_av_stack.sh` to apt path; ~30 min faster install per unit. |
| Partial | Keep source build; document in `AV_STACK.md` which packages are apt vs. source. |
| None | Stay with full source build; revisit for Isaac ROS 4.x / Jazzy. |

<!-- RESULT: -->

## §3.5 — `/dev/ttyTHS1` enumeration

**Item**: Confirm `/dev/ttyTHS1` enumerates post-flash and Pixhawk TELEM2 talks on it.

```bash
dmesg | grep -E 'tty(THS|S)' | tee \
    /var/log/jetson-rt-stack/field-confirm/tty-enum-$(date +%s).log

sudo stty -F /dev/ttyTHS1 921600 raw -echo
sudo timeout 3 cat /dev/ttyTHS1 | xxd | head -50
# Expected: MAVLink magic byte 0xfd (MAVLink 2) or 0xfe (MAVLink 1) regularly

ros2 launch mavros apm.launch fcu_url:=/dev/ttyTHS1:921600 &
sleep 8
ros2 topic echo /mavros/state --once
# Expected: connected: true
```

**Pass criteria**: `ttyTHS1` enumerates AND `mavros/state` reports `connected: true`.

If enumerated at a different `ttyTHS*` index, update `versions.env` `FCU_TTY_DEFAULT` and add a row to the carrier compatibility table in `index.md`.

<!-- RESULT: -->

## §3.6 — HV rail + MAXN_SUPER — safety-critical

**Item**: Confirm the carrier's HV DC-in rail can sustain 40 W MAXN_SUPER without brownout or thermal shutdown. **Do NOT enable Super Mode for flight before this is verified.**

**Pre-flight setup**: bench only, active cooling confirmed, 12 V bench supply current-limited at 5 A, multimeter on V_IN and 5V rail.

```bash
# Baseline at MAXN (25 W)
sudo nvpmodel -m 0 && sudo jetson_clocks
tegrastats --interval 1000 > /var/log/jetson-rt-stack/field-confirm/super-baseline-$(date +%s).log &
TS_PID=$!
scripts/run_sustained_load.sh 300
kill $TS_PID

# Step to MAXN_SUPER
sudo nvpmodel --available    # confirm index (often 4, can vary)
sudo nvpmodel -m 4 && sudo jetson_clocks
tegrastats --interval 1000 > /var/log/jetson-rt-stack/field-confirm/super-maxn-$(date +%s).log &
TS_PID=$!
scripts/run_sustained_load.sh 600
kill $TS_PID
```

**Pass criteria**:

| Metric | Threshold |
|---|---|
| V_IN minimum during 10 min MAXN_SUPER | ≥ 10.5 V on a 12 V supply |
| 5V rail minimum | ≥ 4.85 V |
| tegrastats thermal markers | No `@` suffix (no throttling) |
| Junction temperature peak | ≤ 85 °C with the carrier's stock thermal solution |
| dmesg | No PCIe link retrains, no nvgpu faults |
| Pixhawk heartbeats | Unbroken throughout via TELEM2 |

If any threshold fails: leave `power.conf` at `NVPMODEL_MODE=0`. If all pass: set `NVPMODEL_MODE=4` in `power.conf` and update the home page to drop the "unverified" qualifier on the Super Mode line.

<!-- RESULT: -->
