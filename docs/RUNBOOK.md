---
title: Runbook
layout: default
description: "Operational decision trees for the repeat operator: re-flash, recovery, debugging failures, and maintaining a production fleet."
nav_order: 4
---

# Runbook

First build: [Quickstart]({{ '/QUICKSTART' | relative_url }}). Failures: [Troubleshooting]({{ '/TROUBLESHOOTING' | relative_url }}).

## R1 — Flash a brand-new Jetson

```
make doctor          # 30 s — abort here on any FAIL
make ignite-no-flash # 60–90 min — produces a clean, audited image
                     # Now plug the Jetson in recovery mode.
make flash           # 15–25 min
                     # Wait for boot; first-boot service runs ~3–5 min then reboots.
make verify          # post-flash gauntlet
```

Or:

```bash
make ignite          # doctor → all → audit → flash (interactive) → verify
```

---

## R2 — Changed a CONFIG flag — minimum rebuild?

```
Did you change LOCALVERSION, PREEMPT_RT, MODVERSIONS, or anything that
changes UTS_RELEASE or vermagic constituents?
   yes → full rebuild path: make clean && make all && make audit && make flash
   no  → try the partial path:
         make extract             # idempotent — only re-applies changed patches
         make build               # rebuilds kernel + all modules + headers .deb
         make bake                # restages payloads
         make audit               # confirms gates still green
         make flash               # write
```

Always end with `make verify` post-flash.

---

## R3 — Changed a kernel patch — minimum rebuild?

```bash
# Edit scripts/01_extract_and_patch.sh or KERNEL_PATCHES.md instructions
make clean         # most reliable — patches are not always reversible
make all && make audit
# … recovery mode …
make flash && make verify
```

Skipping `make clean` after a patch change risks Phase 1 silently no-op'ing
because of idempotency guards.

---

## R4 — Audit failed

`pre_flash_audit.sh` prints which check FAILed. Decode:

| Failed check | Most likely cause | Fix |
|---|---|---|
| Version String | Phase 2 ran with wrong LOCALVERSION | rebuild Phase 2 |
| Real-Time Core | PREEMPT_RT not active in built kernel | check defconfig, run `generic_rt_build.sh enable`, rebuild |
| DMABUF Heaps | CONFIG_DMABUF_HEAPS=y missing | check defconfig injection ran in Phase 1 |
| PCIe Retries | LINK_WAIT_MAX_RETRIES != 100 | re-run Phase 1 (sed forces 100) |
| CPU Isolation | extlinux.conf missing isolcpus | re-run `make bake` |
| Tickless Mode | extlinux.conf missing nohz_full | re-run `make bake` |
| CMA Reservation | extlinux.conf missing cma=2G | re-run `make bake` |
| ZED X Overlay | DTBO missing in `/boot/` | re-run Phase 2 (DTBO compile is in 02_build_kernel.sh) |
| Module Vermagic | At least one .ko has wrong vermagic | `make clean && make all` (never partial) |

After fixing, re-run `make audit`. If you can't get it green, gather logs
(`make logs`) and consult `docs/TROUBLESHOOTING.md` §B.

---

## R5 — Flash hangs

Decision tree:

```
1. lsusb -t
   - Jetson on a hub or extender? → move to direct motherboard port.
   - Multiple USB devices on same controller? → unplug others.

2. lsusb | grep 0955
   - Nothing? → Jetson is not in recovery mode. Power off, re-short
     REC+GND, re-power.
   - Shows 0955:7323? → recovery OK; flash should be progressing.

3. ip link show
   - Look for usb0. If absent, the RNDIS gadget didn't enumerate on
     the host. Check dmesg for the rndis_host module loading.
   - sudo modprobe rndis_host
   - sudo udevadm control --reload-rules

4. sudo dmesg -w  (in another terminal)
   - Watch for USB enumeration / disconnect events.

5. Verify USB autosuspend is off:
   sudo sh -c 'echo -1 > /sys/module/usbcore/parameters/autosuspend'
   sudo sh -c 'echo 200 > /sys/module/usbcore/parameters/usbfs_memory_mb'

6. Re-run: make flash
```

If still stuck, `make logs` and see `docs/TROUBLESHOOTING.md` §F.

---

## R6 — Jetson boots but verify_tuning shows FAILs

Common patterns:

```
RT Kernel: FAIL
   → boot landed on the stock kernel. Likely: wrong kernel image written,
     or extlinux.conf points at wrong label. SSH in and check
     /boot/extlinux/extlinux.conf default label.

CPU Isolation: FAIL
   → extlinux.conf missing isolcpus. First-boot script may have failed
     before the inject step. Run it manually:
       sudo /home/j/jetson_first_boot.sh
       sudo reboot

CMA Reservation: FAIL
   → CONFIG_CMA_SIZE_MBYTES wasn't 2048 in the built kernel,
     or boot arg cma=2G is missing.
     - dmesg | grep CMA — what does the kernel report?
     - cat /proc/cmdline — boot arg present?
     If both wrong: kernel wasn't built with our defconfig. Rebuild.

Axelera Metis: GHOST
   → PCIe link train failed. See docs/KERNEL_PATCHES.md §1.
     Most likely the LINK_WAIT_MAX_RETRIES=100 patch didn't apply.

ZED X Driver: MISSING
   → sl_zedx.ko not loaded. Check vermagic:
       modinfo /lib/modules/$(uname -r)/.../sl_zedx.ko | grep vermagic
     If vermagic doesn't include $(uname -r) → mismatch. Re-flash with
     a fresh build.
```

---

## R7 — Vermagic mismatch

Never force-load. Rebuild.

```bash
make clean
make all          # kernel + all modules + headers .deb in one Docker run
make audit        # verify_vermagic.sh --rootfs gates here
make flash
```

Never run `insmod --force`. Never `apt install nvidia-l4t-kernel-modules`.
The `Pin-Priority: -1` in `/etc/apt/preferences.d/99-jetson-av-kernel-lock`
should already block it, but operator discipline is the final defense.

See `docs/VERMAGIC_STRATEGY.md`.

---

## R8 — Install ZED SDK / Voyager SDK after first boot

First-boot handles this if artifacts were staged at bake time. If not:

```bash
# On the target
ls /opt/zed-sdk/ZED_SDK_Tegra_*.run             # already there?
sudo /opt/zed-sdk/install_zed_sdk.sh           # idempotent

# Voyager SDK (pip wheels — not install.sh)
sudo /opt/av-env/bin/pip install axelera-rt axelera-devkit \
    --extra-index-url https://software.axelera.ai/artifactory/axelera-pypi/
```

Both depend on the linux-headers .deb being installed (handled by
first-boot). Confirm with `dpkg -l | grep linux-headers`.

---

## R9 — OTA update overwrote the kernel

If `apt upgrade` proposes `nvidia-l4t-kernel*` — decline. First-boot pins these at `Pin-Priority: -1`.

If it ran anyway:

```bash
# Confirm damage
uname -r              # should be 5.15.x-tegra
                       # if not, kernel is stock again

# Recovery: re-flash from a fresh build
make clean && make all && make audit && make flash
```

There is no in-place repair — module ABI is ruined the moment a stock
kernel boots.

---

## R10 — Fleet-deploy multiple Jetsons

Build once. Reuse `latest_jetson/` for each subsequent flash:

```bash
# Build once (or pull pre-built from CI)
make doctor
make all        # produces deterministic artifacts (SOURCE_DATE_EPOCH locked)
make audit

# Per-device: just put each Jetson in recovery mode, then
make flash      # rewrites the same image
make verify     # confirm
```

To validate two builds are byte-identical (for fleet QA):

```bash
sha256sum latest_jetson/Linux_for_Tegra/kernel/Image
sha256sum latest_jetson/Linux_for_Tegra/staging/kernel-headers/linux-headers-*.deb
sha256sum latest_jetson/Linux_for_Tegra/kernel/dtb/*.dtbo
```

See `docs/BUILD.md` §Reproducibility for the full theory.

---

## R11 — Bundle logs for a support request

```bash
make logs
```

Produces `support-bundle-YYYYMMDD-HHMMSS.tar.gz` containing:

- `BUILD_LOG.md`, `FLASH_LOG.txt`, `IGNITION_*.log`
- `EXPECTED_VERMAGIC`, `BUILD_MANIFEST.json`
- staged defconfig and extlinux.conf
- vermagic snapshot (`vermagic-rootfs.txt`)
- if target reachable: `target-uname.txt`, `target-dmesg-err.txt`,
  `target-journal-{first-boot,rt-tune}.txt`, `target-hardware.txt`,
  `target-vermagic.txt`

Attach the tarball to your support ticket.

---

## R12 — Check pinned versions

```bash
make versions
```

Reads `versions.env` and prints every pinned version, URL, USB ID, and
RT tuning value. Also prints last-build vermagic and manifest if a build
has run.

---

## R13 — Release tarball + batch flash N units

```bash
make doctor                        # preflight
make all && make audit             # build + gate

GPG_KEY=YOUR_KEY make release VERSION=v1.0.0   # signed release tarball
                                                # → releases/release-v1.0.0.tar.gz

# On the flash station(s):
make fleet-init                    # creates fleet.csv from example
$EDITOR fleet.csv                  # add device labels + hostnames + IPs
make flash-batch FLEET=fleet.csv   # iterates devices; per-device PASS/FAIL log

make fleet-status                  # summarize fleet_log.csv
```

Full workflow in `docs/FLEET.md`.

---

## R14 — Verify resilience layer

```bash
ssh j@av-07 << 'EOF'
    systemctl is-active systemd-journald jetson-blackbox.service \
                       jetson-brownout-guard.service tmp.mount
    cat /etc/jetson-av-resilience-installed
    journalctl --disk-usage
    chronyc tracking | head -3
    sudo ufw status verbose
    ls /var/log/jetson-av/flights/
EOF
```

Each line should report a healthy state. The post-flash validator
(`make verify`) does most of these automatically.

Force a black-box flush before powering off (e.g., aborting a flight):

```bash
ssh j@av-07 'sudo kill -USR1 $(systemctl show jetson-blackbox -p MainPID --value)'
```

Full guide in `docs/UAV_RESILIENCE.md` and `docs/BLACKBOX.md`.

---

## R15 — Verify AV stack (GPU / Metis / DLA)

```bash
ssh j@av-07 'jetson-av-version'                 # build identity
ssh j@av-07 'sudo /home/j/phase5/verify_opengl_cuda.sh'   # CUDA stack
ssh j@av-07 'ros2 pkg list | grep -E "isaac_ros|nav2"'
ssh j@av-07 'sudo /usr/local/bin/launch_av_mission.sh --dry-run'
```

To start the mission:

```bash
ssh j@av-07 'sudo systemctl start jetson-av-mission.service'
ssh j@av-07 'systemctl status "jetson-av-*"'
```

Inspect at runtime:

```bash
ssh j@av-07 'ros2 topic hz /zed/zed_node/rgb/image_rect_color'   # camera
ssh j@av-07 'ros2 topic hz /detections'                          # Metis
ssh j@av-07 'ros2 topic echo /vslam/pose --once'                 # SLAM
```

Full guide in `docs/AV_STACK.md` and `docs/CUDA_LIBS.md`.

---

## R16 — Clone a configured Jetson to N units

Flash one unit with `make ignite`, install apps + ROS packages + models, validate. Then:

```bash
# On Jetson #0 (the golden), boot, install everything, validate.
# Then power off, put it in APX recovery mode, and from the host:

make clone-golden TAG=v1.0-bench-validated
# → golden-images/golden-v1.0-bench-validated-<timestamp>/

make list-goldens                                 # confirm

# For each receiving Jetson (in recovery mode each):
make flash-golden GOLDEN=golden-v1.0-bench-validated-<ts> DEVICE=av-07
make verify
```

Every clone runs `personalize_first_boot.sh` at first boot → unique
hostname + SSH host keys + optional static IP. So bit-identical at flash
time, divergent identity at boot.

Full guide in `docs/GOLDEN_IMAGE.md`.

---

## R17 — Audit step manifest

`logs/STEP_MANIFEST.tsv` records every step. To query:

```bash
column -t -s$'\t' logs/STEP_MANIFEST.tsv | tail -50

# Just the failures:
awk -F$'\t' '$4!="PASS" && $4!="SKIPPED" && NR>1' logs/STEP_MANIFEST.tsv

# Time spent per phase:
awk -F$'\t' 'NR>1 {s[$3]+=$5} END {for (p in s) printf "  %-12s %ds\n", p, s[p]}' \
    logs/STEP_MANIFEST.tsv
```

Per-step logs are at `logs/<timestamp>_<slug>.log` and bundled by
`make logs`. See `docs/VERIFICATION.md`.
