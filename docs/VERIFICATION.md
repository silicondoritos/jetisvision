---
title: Verification Framework
layout: default
description: "How the step::run pre/post-gate framework works and how to write new verification checks for build, flash, and runtime phases."
nav_order: 41
---

# Verification Framework

Every step: pre-check → execute → post-check, with per-step logs and append-only manifest.

## Concepts

A **step** is one unit of work — extract a tarball, install a package,
flash a partition, register a service. Every step has three functions:

- **`pre_fn`** — assert the preconditions (file exists, command available,
  expected state). Returns 0 if OK, non-zero if not.
- **`exec_fn`** — perform the work. Returns 0 on success.
- **`post_fn`** — assert the postconditions (artifact produced, service
  active, value present). Returns 0 if achieved.

The `step::run` function (in `scripts/lib/verify.sh`) glues them together:

```
log section banner
log step start
run pre_fn          → fail-fast if preconditions broken
run exec_fn         → fail; ALSO run post-check for forensics
run post_fn         → fail if work didn't achieve target state
record result row in STEP_MANIFEST.tsv
```

Per-step output is captured to `logs/<timestamp>_<slug>.log`. The
manifest at `logs/STEP_MANIFEST.tsv` is append-only TSV:

```
timestamp        step           phase    result    duration_s    log_path
2026-05-06T...   Extract L4T    extract  PASS      12            logs/...
2026-05-06T...   Build kernel   build    PASS      4612          logs/...
2026-05-06T...   Vermagic gate  build    POST_FAIL 3             logs/...
```

## Switches

| Env var | Default | Effect |
|---|---|---|
| `DEBUG` | `0` | `1` enables `bash -x` tracing inside the per-step log |
| `DRY_RUN` | `0` | `1` runs pre+post but skips execute (planning mode) |
| `STRICT` | `1` | `1` aborts the entire script on any step failure; `0` continues, accumulates, summarizes at end |
| `STEP_LOG_DIR` | `$REPO_ROOT/logs` | where per-step logs land |
| `STEP_MANIFEST` | `$STEP_LOG_DIR/STEP_MANIFEST.tsv` | the audit trail |
| `NO_COLOR` | `0` | `1` disables ANSI color (already auto-off when not a TTY) |
| `NO_EXIT` | `0` | `1` makes `log::fail` print but not exit (rare; for tests) |

Examples:

```bash
DEBUG=1 ./scripts/install_uav_phase7.sh        # verbose trace into log
DRY_RUN=1 ./scripts/release.sh v1.0.0          # plan only, no work done
STRICT=0 ./scripts/install_av_phase5.sh        # don't abort on first failure
NO_COLOR=1 ./scripts/00_doctor.sh > preflight.txt   # plain text for piping
```

## Authoring a new step-driven script

```bash
#!/bin/bash
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/config.sh"
. "$HERE/lib/log.sh"
. "$HERE/lib/verify.sh"
. "$HERE/lib/checks.sh"

PHASE=mything                # tag every step with a phase

pre_thing()  { check::file_exists /etc/something; }
exec_thing() { do_real_work; }
post_thing() {
    check::service_active mything &&
    check::file_exists /var/run/mything.pid
}

step::run "Install mything" pre_thing exec_thing post_thing
step::summary
```

`check::*` is a library of common assertions (see `scripts/lib/checks.sh`):

- File / dir: `file_exists`, `dir_exists`, `dir_nonempty`, `executable`,
  `file_contains`, `file_not_contains`, `file_size_gt`
- Command / package: `command_exists`, `package_installed`,
  `python_module_importable`
- Kernel / module: `module_loaded`, `vermagic_matches_running`,
  `kernel_cmdline_has`, `config_y`
- PCIe / USB / hardware: `pci_device_visible`, `usb_device_visible`
- systemd: `service_active`, `service_enabled`
- Network: `host_pingable`, `tcp_open`
- Numeric: `value_gt`, `value_eq`

If you need a new check, add it to `lib/checks.sh` rather than inlining
in the script — it's likely useful elsewhere.

## Skipping a step intentionally

```bash
if [ -z "$GPG_KEY" ]; then
    step::skip "GPG sign release" "GPG_KEY not set"
else
    step::run "GPG sign release" pre_sig exec_sig post_sig
fi
```

Skipped steps appear in the manifest as `SKIPPED` so later audits know
the difference between "didn't run" and "ran and passed".

## Reading the manifest later

```bash
column -t -s $'\t' logs/STEP_MANIFEST.tsv | tail -50

# Just the failures:
awk -F'\t' '$4 != "PASS" && $4 != "SKIPPED" && NR>1 {print}' logs/STEP_MANIFEST.tsv

# Total time spent in a phase:
awk -F'\t' '$3=="build" {s += $5} END {print s, "seconds"}' logs/STEP_MANIFEST.tsv
```

## Where the framework is used

| Script | Pre/post-gated steps |
|---|---|
| `scripts/release.sh` | workspace check, audit, stage tree, tar, sha+manifest, sign, cleanup |
| `scripts/flash_release.sh` | release integrity, recovery detect, USB tuning, RNDIS udev, prereqs, apply_binaries, l4t_initrd_flash, fleet log |
| `scripts/flash_one.sh` | audit, flash, settle, validate, fleet log |
| `scripts/install_uav_phase7.sh` | resilience, blackbox, brownout, mavlink |
| `scripts/install_av_phase5.sh` | OpenCV-CUDA, OpenGL/CUDA verify, ROS+Isaac+Nav2+MAVROS, mission service |
| `scripts/build_opencv_cuda.sh` | cache hit, deps, sources, build, package |

The existing Phase 1–4 scripts (`01_extract_and_patch.sh`,
`02_build_kernel.sh`, etc.) predate this framework; they have their own
audit gates (`pre_flash_audit.sh`) but are not yet step-driven. They can
be retrofitted incrementally without breaking anything.

## Bundling for support

A failed step's log lives at `logs/<timestamp>_<slug>.log`. To bundle
everything for a support request:

```bash
make logs           # produces support-bundle-*.tar.gz including the manifest
```

The bundle includes `STEP_MANIFEST.tsv` and every per-step log file.
