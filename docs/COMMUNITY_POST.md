---
title: Full Tutorial
layout: default
description: "Long-form tutorial: every command, every failure mode, and every hardware issue for building and deploying the RT vision stack on Jetson Orin NX."
nav_order: 3
---

# use the metis m.2, zed x, nvme and an e-key network card on a jetson orin nx 16gb — the long version

> *a comprehensive guide to running a full RT vision stack on the Jetson Orin NX 16GB — built from the original Axelera community bring-up guide.
> this version covers every command, every failure mode, and every fix required to run this stack in a flyable state.*

---

## what this is

a complete recipe for taking a stock jetson orin nx 16gb and turning
it into a fleet-deployable autonomous-vehicle compute platform with:

- **custom preempt_rt kernel** with low-jitter tuning (cyclictest <100µs
  on isolated cores)
- **dmabuf zero-copy pipeline** from the camera through the isp to the
  npu — no cpu memcpy
- **axelera metis m.2** as the inference accelerator (in-tree driver,
  not oot — vermagic-clean)
- **stereolabs zed x stereo camera** via the **zed link mono** capture
  card (max9296 deserializer)
- **nvme** boot + a btrfs data partition for black-box recordings
- **realtek wi-fi/bt** in the m.2 key e slot
- **pixhawk 6x flight controller** over mavros (the right uart this
  time)
- **iridium sbd failover** (rockblock 9704 — which uses a different
  protocol than the older 9602/9603 i kept reading about, more on that
  below)
- **fleet manufacturing** workflow: build once, flash N units, each
  with unique identity
- **golden-image clone**: validate one fully-customized jetson, capture
  its nvme bit-for-bit, redeploy that exact state to the rest of the
  fleet

it's all in one repo:
**https://github.com/silicondoritos/jetson-rt-stack** (apache 2.0).

it builds on the original axelera bring-up guide and `axl-jetson.patch`
from the axelera team. 20 corrections relative to earlier versions of
this guide are documented in `VERIFICATION_REPORT.md` with source urls.

---

## table of contents

scope: jetson orin nx 16gb (P3767 module, P3509-class carrier).
the M.2 PCIe coexistence problem (metis on key M + nvme on key M +
realtek on key E) is the actual headline.

- [part 1: setup](#part-1--setup)
  - host machine
  - source archives (and the url that 404s now)
  - vendor trees (the one stereolabs doesn't publish)
- [part 2: the custom kernel](#part-2--the-custom-kernel)
  - phase 1: extract + patch
  - the defconfig — every knob, every reason
  - phase 2: build
  - the dtbo trap nobody warns you about
  - vermagic — the deep dive
- [part 3: drivers](#part-3--drivers)
  - axelera metis: in-tree, not oot (M.2 PCIe gen3 x4)
  - zed x + zed link mono (and the kernel-driver-source problem)
  - nvme — durable data partition
- [part 4: bake, flash, first boot](#part-4--bake-flash-first-boot)
- [part 5: telemetry + the av stack](#part-5--telemetry-and-the-av-stack)
  - mavlink + iridium failover (yes, the 9704 is different)
  - opencv with cuda (the apt package isn't enough)
  - ros 2 + isaac ros + nav2 + mavros
- [part 6: validation, fleet, golden image](#part-6--validation-fleet-golden-image)
- [part 7: troubleshooting catalog](#part-7--troubleshooting-catalog)
- [closing](#closing)

---

## part 1 — setup

### who this is for

if you've got an orin nx 16gb, an axelera metis m.2, a zed x stereo
camera, and you want them all running on the same machine in a
real-time-tuned kernel — this is for you. if any of those is missing,
parts of this guide still apply but you'll skip the relevant sections.

all corrections relative to earlier guides are documented in
[VERIFICATION_REPORT.md](VERIFICATION_REPORT.md) with the vendor source
urls used to verify them. notable fixes: board target (`-super` is wrong
for orin nx), pcie retries (100, not 50), bootlin toolchain url (v3.0,
not v5.0), board target power profile, and vermagic discipline.

### host machine

ubuntu 22.04 lts only. some nvidia tools refuse to run on 24.04. the
build container is also ubuntu 22.04, so even if your host is newer
you can do this — but you need docker.

minimum:
- 16 gb ram (32 gb recommended for parallel kernel builds)
- 100 gb free disk on the partition that'll hold the workspace (200 gb
  if you want comfortable golden-image storage)
- direct usb-c cable to the jetson — not a hub, not an extender, not a
  docking station. i learned this twice.

packages:

```bash
sudo apt update
sudo apt install -y \
    build-essential bc bison flex git rsync zstd make openssl xxd \
    libssl-dev dpkg-dev qemu-user-static device-tree-compiler \
    nfs-kernel-server docker.io curl

sudo usermod -aG docker $USER
newgrp docker   # or log out and back in
```

if you're going to run `make doctor` (you should), it tells you which
of these are missing rather than letting the build fail two hours in.

### source archives

all l4t r36.5 archives live under `r36_release_v3.0/` on nvidia's cdn
(the toolchain url circulating in older guides with `v5.0` 404s —
nvidia moved everything to v3.0):

```bash
mkdir -p ~/jetson_workspace && cd ~/jetson_workspace

# l4t bsp (bootloader, tools, scripts) — ~1 gb
wget https://developer.nvidia.com/downloads/embedded/l4t/r36_release_v3.0/release/Jetson_Linux_R36.5.0_aarch64.tbz2

# sample rootfs (ubuntu 22.04 jammy) — ~1 gb
wget https://developer.nvidia.com/downloads/embedded/l4t/r36_release_v3.0/release/Tegra_Linux_Sample-Root-Filesystem_R36.5.0_aarch64.tbz2

# public sources (kernel + oot modules) — ~250 mb
wget https://developer.nvidia.com/downloads/embedded/l4t/r36_release_v3.0/sources/public_sources.tbz2
```

these go next to the repo, not inside it. the `make extract` step
extracts them into `latest_jetson/`.

### vendor trees

three external trees that are NOT in the repo (they're gitignored):

| dir | source | required for |
|---|---|---|
| `axelera-driver/` | axelera customer portal (NDA) | metis kernel module |
| `voyager-sdk/` | axelera customer portal (NDA) | `axl-jetson.patch` + inference runtime pip wheels |
| `zedx-driver/` | stereolabs business / NDA — contact support | zed x in-tree driver (full vision stack) |
| `zed-sdk/` | [stereolabs.com/developers/release](https://www.stereolabs.com/developers/release) (public) | zed sdk userspace + pyzed (full vision stack) |

**on the zed x driver**: stereolabs doesn't publish the zed x kernel
driver as open source. they ship compiled `.deb` packages built against
the **stock** nvidia l4t kernel — those packages will not load on our
preempt_rt kernel because the vermagic won't match. you need the source
under a business / nda agreement. place it at `zedx-driver/` and the
plugin system promotes it in-tree automatically.

without `zedx-driver/` the baseline (metis + nvme + wi-fi) still
builds and works. `make doctor` will warn but won't fail. revisit when
you have source.

### confirming you have everything

```bash
git clone https://github.com/silicondoritos/jetson-rt-stack.git
cd jetson-rt-stack

# stage the trees (gitignored)
mv ../axelera-driver  .         # required — metis kernel module
mv ../voyager-sdk     .         # required — patch + inference runtime
mv ../zedx-driver     .         # required for full vision stack (zed x camera)
mv ../zed-sdk         .         # required for full vision stack (zed sdk userspace)

# stage the tarballs at the repo root (also gitignored)
mv ../Jetson_Linux_R36.5.0_aarch64.tbz2                          .
mv ../Tegra_Linux_Sample-Root-Filesystem_R36.5.0_aarch64.tbz2    .
mv ../public_sources.tbz2                                        .

# preflight
make doctor
```

`make doctor` walks every prereq and tells you what's missing with the
exact remediation command. green or yellow is fine; red means stop.

---

## part 2 — the custom kernel

this is the heart of it. four distinct things happen here:

1. extract l4t and inject vendor sources (phase 1 / `make extract`)
2. patch defconfig + apply pcie retry / max9296 fixes (phase 1)
3. cross-compile inside docker (phase 2 / `make build`)
4. compile the zed x dtbo because nvidia's build system silently
   skips it (phase 2)

### phase 1: extract + patch

```bash
make extract
```

what `scripts/01_extract_and_patch.sh` does, with rationale:

#### 1.1 unpack the bsp

```bash
tar xf Jetson_Linux_R36.5.0_aarch64.tbz2
sudo tar xpf Tegra_Linux_Sample-Root-Filesystem_R36.5.0_aarch64.tbz2 \
    -C Linux_for_Tegra/rootfs/
tar xf public_sources.tbz2 -C .

cd Linux_for_Tegra/source
tar xf kernel_src.tbz2
tar xf kernel_oot_modules_src.tbz2
tar xf nvidia_kernel_display_driver_source.tbz2
```

note: the rootfs extract needs `sudo` because it preserves device
nodes. on a host without passwordless sudo, the script prints exactly
what to run and exits — no half-done state.

#### 1.2 inject vendor sources

```bash
# zed x driver tree (only if you have source)
cp -r ../zedx-driver/src/kernel/stereolabs   Linux_for_Tegra/source/
cp -r ../zedx-driver/src/hardware/stereolabs Linux_for_Tegra/source/hardware/

# axelera driver tree
sudo rsync -av --exclude='.git' \
    ../axelera-driver/ \
    Linux_for_Tegra/source/axelera/axelera-driver/

# axelera udev rules (so the runtime can find /dev/axelera*)
sudo cp ../axelera-driver/udev/72-axelera.rules \
    Linux_for_Tegra/rootfs/etc/udev/rules.d/
```

#### 1.3 apply the zed x r36.5 patches

these are only present if you have stereolabs source. they integrate
the zed x driver into the nvidia kernel oot build tree:

```bash
for patch in ../zedx-driver/nvidia_kernel/kernel_patches/R36.5/0*.patch; do
    if [[ "$patch" != *"zedbox"* ]]; then
        patch -p2 -N -d Linux_for_Tegra/source < "$patch" || true
    fi
done
```

#### 1.4 fix the dtbo prefix bug

the zed x patches register dtbo overlays with a path prefix that
nvidia's makefile **also** adds. you get a doubled path
(`t23x/nv-public/t23x/nv-public/...`), the dtbo silently doesn't build:

```bash
sed -i 's|dtbo-y += \$(makefile-path)/\(.*-sl-overlay\.dtbo\)|dtbo-y += \1|g' \
    Linux_for_Tegra/source/hardware/nvidia/t23x/nv-public/Makefile
```

#### 1.5 the max9296 vs max96712 silent-corruption fix

**Note:** zed link mono uses the **max9296** gmsl2
deserializer. there's a similar product (zed link duo / quad) that
uses **max96712**. if you select the wrong deserializer, the camera
**still works** at 30fps with no errors in dmesg, frames look right —
but **stereo depth is garbage and slam drifts**. silent data
corruption.

we enforce the choice in two places. first, in the defconfig (next
section): `CONFIG_SL_DESER_MAX9296=m`,
`# CONFIG_SL_DESER_MAX96712 is not set`.

second, the vendor's `drivers/Makefile` hardcodes a `-D` flag that the
defconfig doesn't override. we sed it:

```bash
sed -i 's/-DCONFIG_SL_DESER_MAX96712/-DCONFIG_SL_DESER_MAX9296/g' \
    Linux_for_Tegra/source/stereolabs/drivers/Makefile
```

both changes must be in place. one without the other = corrupted
frames.

#### 1.6 the pcie patience patch — `LINK_WAIT_MAX_RETRIES`

**Note:** the metis is invisible to `lspci` on cold boot.
`lspci -d 1f9d:` returns nothing. modprobe says the device isn't
there. once the system has been warm for a while, it just appears.

root cause: nvidia's pcie link-training timeout in
`drivers/pci/controller/dwc/pcie-designware.h` is `10` retries by
default. that's enough at room temp from a stable bench psu. it is
**not enough** on an autonomous platform with a brief brownout during arming, or on a
cold day where the dc-dc converter takes 50ms longer to settle.

the original `axl-jetson.patch` from axelera bumped it to 50. that
worked on my bench. **at -10°C from a flight battery i still saw
ghost-on-cold-boot.** so:

```bash
PCIE_HEADER="Linux_for_Tegra/source/kernel/kernel-jammy-src/drivers/pci/controller/dwc/pcie-designware.h"
sed -i 's/#define LINK_WAIT_MAX_RETRIES\t[0-9]*/#define LINK_WAIT_MAX_RETRIES\t100/g' "$PCIE_HEADER"
```

`100` is what works. it's also what the script forces regardless of
whether `axl-jetson.patch` ran first.

### the defconfig — every knob, every reason

now we append our additions to
`Linux_for_Tegra/source/kernel/kernel-jammy-src/arch/arm64/configs/defconfig`.
this is the longest, densest part of the whole pipeline. broken into
thematic groups:

#### real-time core

```
CONFIG_PREEMPT_RT=y
CONFIG_NO_HZ_FULL=y
CONFIG_HZ_1000=y
# CONFIG_HZ_250 is not set
CONFIG_CPU_ISOLATION=y
CONFIG_RCU_NOCB_CPU=y
CONFIG_IRQ_FORCED_THREADING=y
CONFIG_HIGH_RES_TIMERS=y
CONFIG_HZ=1000
CONFIG_RCU_BOOST=y
CONFIG_RCU_BOOST_DELAY=500
# CONFIG_PREEMPT_DYNAMIC is not set
# CONFIG_NO_HZ_IDLE is not set
# CONFIG_NUMA_BALANCING is not set
# CONFIG_SCHED_AUTOGROUP is not set
# CONFIG_LATENCYTOP is not set
CONFIG_CPU_FREQ_DEFAULT_GOV_PERFORMANCE=y
# CONFIG_CPU_FREQ_DEFAULT_GOV_SCHEDUTIL is not set
# CONFIG_CPU_FREQ_GOV_ONDEMAND is not set
# CONFIG_CPU_FREQ_GOV_CONSERVATIVE is not set
```

key insights here:

- **`PREEMPT_RT`** is the real-time patch (now upstream in 5.15+).
  spinlocks become sleepable, threaded irq handlers are mandatory.
- **`NO_HZ_FULL`** + **`CPU_ISOLATION`** + **`RCU_NOCB_CPU`** must move
  together. set isolcpus boot arg to the same set as nohz_full and
  rcu_nocbs (we use cores 1–5). drop any one of the three and the
  scheduler / timer / rcu callbacks reintroduce jitter on the
  "isolated" cores.
- **`RCU_BOOST`**: when a high-priority rt task is waiting for an rcu
  grace period, the priority of the rcu reader gets temporarily
  boosted so it can release. without this, rt tasks can stall up to
  10ms behind low-priority kernel threads.
- **`PREEMPT_DYNAMIC` off**: forces fixed preempt_rt instead of
  switchable mode.
- **`NUMA_BALANCING` off**: orin nx is single-numa; balancing wastes
  cycles for nothing.
- **`LATENCYTOP` off**: per-task tracking has measurable overhead.

#### dmabuf zero-copy pipeline

```
CONFIG_SYNC_FILE=y
CONFIG_SW_SYNC=y
CONFIG_DMABUF_HEAPS=y
CONFIG_DMABUF_SYSFS_STATS=y
CONFIG_DMABUF_HEAPS_SYSTEM=y
CONFIG_DMABUF_HEAPS_CMA=y
CONFIG_CMA_SIZE_MBYTES=2048
```

**Note:** stock jetpack reserves **32 mb** of cma. our
pipeline (zed x 4k stereo at 30fps + isp processing + metis dma read
window) needs ~1.4 gb sustained. 32 mb causes silent allocation
failures that show up as "the camera sometimes drops to 5 fps".

`CONFIG_CMA_SIZE_MBYTES=2048` is a defconfig-time reservation. we
also set `cma=2G` as a kernel boot arg in extlinux.conf as
belt-and-suspenders. these are independent paths — both must be set.

#### pcie always-on + aer

```
# CONFIG_PCIEASPM is not set
CONFIG_PCIEPORTBUS=y
CONFIG_PCIEAER=y
CONFIG_PCIE_DPC=y
CONFIG_PCIEAER_INJECT=m
```

**Note:** pcie aspm (active state power management) lets the
link drop to l1/l1.x sleep when idle. on the metis, that means a
50µs wakeup penalty on the next dma transfer. for inference at every
frame, that's a real budget hit. and the wakeup itself is a
correctable error event. we disable aspm at three layers:
defconfig (compile-time), `pcie_aspm=off` boot arg, and per-device
`/sys/bus/pci/devices/*/power/control = on` at every boot.

`PCIEPORTBUS` + `PCIEAER` + `PCIE_DPC`: the **advanced error reporting** subsystem reports
correctable / non-fatal / fatal pcie errors via
`/sys/bus/pci/devices/*/aer_dev_*`. without these configs, those
counters don't exist and you have no visibility into pcie health. on a
power rail with brief sags, you'll see correctable errors before you
see metis disappear from `lspci`. the
`jetson-av-pcie-aer-monitor.service` polls these and emits black-box
events on increases. when something goes wrong post-flight, you can
correlate "metis disappeared at T+1247s" with "aer correctable +3 at
T+1245s" and know the root cause was electrical, not driver.

#### armv8.5 silicon dominion

```
CONFIG_ARM64_PTR_AUTH=y
CONFIG_ARM64_BTI=y
CONFIG_ARM64_BTI_KERNEL=y
CONFIG_CRYPTO_AES_ARM64_CE=y
CONFIG_CRYPTO_SHA512_ARM64=y
CONFIG_KERNEL_MODE_NEON=y
```

cortex-a78ae has hardware pointer authentication (cve mitigation),
branch target identification (cfi), and crypto extensions. all three
free; turn them on.

#### memory + cgroups v2 (for systemd cpuset pinning)

```
CONFIG_TRANSPARENT_HUGEPAGE=y
CONFIG_TRANSPARENT_HUGEPAGE_MADVISE=y
CONFIG_HUGETLB_PAGE=y
CONFIG_USERFAULTFD=y
CONFIG_PAGE_REPORTING=y
# CONFIG_ZSWAP is not set
# CONFIG_ZRAM is not set

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
```

`CGROUP_BPF` + `CPUSETS` are what `systemd-run --scope -p AllowedCPUs=4-5`
uses to actually pin cuvslam to cores 4-5. without these the constraint
is silently ignored.

`ZSWAP` and `ZRAM` off: compression in the swap path is a no-no for rt.

#### networking (ros 2 dds + bbr)

```
CONFIG_NET_SCH_FQ=m
CONFIG_NET_SCH_FQ_CODEL=m
CONFIG_TCP_CONG_BBR=m
CONFIG_DEFAULT_TCP_CONG="bbr"
CONFIG_NET_FOU=m
CONFIG_BPF_JIT=y
CONFIG_BPF_JIT_ALWAYS_ON=y
CONFIG_XDP_SOCKETS=y
CONFIG_NET_RX_BUSY_POLL=y
```

`fq` qdisc on the primary nic prevents one bursting flow from starving
ros 2 dds multicast. our `jetson_rt_tune.sh` sets it on every boot.

#### i/o (nvme, async i/o, usb-serial for fcu + iridium)

```
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
```

- `NVME_HWMON`: temperature monitoring for the boot ssd.
- `IO_URING`: async i/o for ros 2 bag recording at high rates.
- `USB_SERIAL_FTDI_SIO`: pixhawk usb-c connector (when used). also
  what the **rockblock 9704** uses (more on this in part 5).
- `USB_SERIAL_CP210X`: silabs usb-serial bridges (some pixhawk
  alternatives).
- `USB_ACM`: cdc-acm for the legacy rockblock 9602/9603 (and many
  cellular modems).
- `USB_USBNET` + `USB_NET_RNDIS_HOST` + `USB_NET_CDCETHER`: usb-ethernet
  cellular sticks for failover networking.

#### security / hardening (no rt cost)

```
CONFIG_HARDENED_USERCOPY=y
CONFIG_FORTIFY_SOURCE=y
CONFIG_STACKPROTECTOR_STRONG=y
CONFIG_RANDOMIZE_BASE=y
CONFIG_RANDOMIZE_MODULE_REGION_FULL=y
CONFIG_INIT_STACK_ALL_ZERO=y
# CONFIG_DEVMEM is not set
# CONFIG_LEGACY_PTYS is not set
```

**Note:** `# CONFIG_DEVKMEM is not set` was in my defconfig
for months. **devkmem was removed from upstream linux in 5.13.** the
symbol doesn't exist in 5.15. kconfig silently ignores unknown
symbols, so my "we have devkmem off" was a no-op. doesn't matter
functionally (it's already off), but it's emblematic of a class of
silent misconfiguration. now flagged in the defconfig as a comment.

#### resilience / kdump / tpm

```
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
```

**Note:** i had `CONFIG_TPM_HW_RANDOM=y` in my defconfig for
months. **the actual symbol is `CONFIG_HW_RANDOM_TPM`** (in
`drivers/char/hw_random/Kconfig`, not `drivers/char/tpm/Kconfig`).
kconfig silently ignored my line and we got zero entropy from the
tpm. a friend ran a static analysis pass against `torvalds/linux@v5.15`
and found 15 things like this; they're all in
[VERIFICATION_REPORT.md](VERIFICATION_REPORT.md).

#### module discipline

```
CONFIG_MODVERSIONS=y
CONFIG_MODULE_SRCVERSION_ALL=y
# CONFIG_MODULE_FORCE_LOAD is not set
```

`MODVERSIONS` adds per-symbol crc checks **on top of** vermagic. this
is stricter — even if vermagic happens to match, mismatched symbol
crcs are rejected. `MODULE_FORCE_LOAD` off means there's literally no
escape hatch for `insmod --force`. that's a feature, not a bug.

#### in-tree axelera metis + zed x

```
CONFIG_AXELERA_METIS=m

CONFIG_VIDEO_ZEDX=m
CONFIG_VIDEO_ZEDX_AR0234=m
CONFIG_VIDEO_ZEDX_IMX678=m

CONFIG_SL_DESER_MAX9296=m
# CONFIG_SL_DESER_MAX96712 is not set
```

these only fire if `scripts/01_extract_and_patch.sh` generated the
in-tree shims under `drivers/misc/axelera/` and
`drivers/media/i2c/zedx/`. see part 3 for the actual code.

#### debug stripping (every cycle counts)

```
# CONFIG_KASAN is not set
# CONFIG_PROVE_LOCKING is not set
# CONFIG_DEBUG_LOCKDEP is not set
# CONFIG_SLUB_DEBUG is not set
# CONFIG_KMEMLEAK is not set
# CONFIG_FUNCTION_GRAPH_TRACER is not set
# CONFIG_DYNAMIC_FTRACE is not set
# CONFIG_SCHED_DEBUG is not set
# CONFIG_FUNCTION_TRACER is not set
# CONFIG_DEBUG_PREEMPT is not set
# CONFIG_DEBUG_RT_MUTEXES is not set
# CONFIG_PROVE_RCU is not set
# CONFIG_TIMER_STATS is not set
# CONFIG_DEBUG_VM is not set
```

**Note:** with `KASAN` + `FUNCTION_GRAPH_TRACER` +
`PROVE_LOCKING` enabled (the default debug setup nvidia ships), my
cyclictest max latency was **180-220 µs**. with all debug stripped,
i'm at **30-50 µs**. that's the difference between "this works for
manual control" and "this can autonomously avoid an obstacle at 20
m/s". turn it off.

#### final phase 1 step

`./generic_rt_build.sh "enable"` — this is nvidia's helper that flips
a few additional `CONFIG_PREEMPT_*` options that the rt patch expects.
it runs after our defconfig appends. if you skip it, the build will
warn about preempt_rt being requested but not fully active.

### phase 2: build inside docker

```bash
make docker-build   # one-time: builds the cross-compile container
make build          # runs scripts/02_build_kernel.sh inside docker
```

inside the container:

```bash
export CROSS_COMPILE=/opt/aarch64--glibc--stable-2022.08-1/bin/aarch64-buildroot-linux-gnu-
export ARCH=arm64
export LOCALVERSION=-tegra
export IGNORE_PREEMPT_RT_PRESENCE=1
export KERNEL_HEADERS=$PWD/kernel/kernel-jammy-src
export SOURCE_DATE_EPOCH=$(git -C "$REPO_ROOT" log -1 --format=%ct)
export LC_ALL=C
export LANG=C

# build
make -C kernel -j$(nproc)
make modules -j$(nproc)
make dtbs -j$(nproc)

# install
sudo -E make install -C kernel
INSTALL_MOD_PATH=$ROOTFS sudo -E make modules_install
```

the env vars matter:

- **`LOCALVERSION=-tegra`**: the suffix that ends up in
  `uname -r` (`5.15.x-tegra`). everything that follows
  identifies "this kernel" by this string.
- **`SOURCE_DATE_EPOCH`**: pinning to the git head commit time so two
  builds of the same commit produce byte-identical artifacts. this is
  what makes `make release` deterministic and the golden-image flow
  reproducible.
- **`LC_ALL=C` / `LANG=C`**: stops `find` / `ls` / `sort` from
  ordering files differently on hosts with different locales.

### the dtbo trap nobody warns you about

**Note:** nvidia's kernel build system silently skips
`dtbo-y` targets. that's right — you can put your overlay in
`drivers/.../Makefile` as `dtbo-y += my-overlay.dtbo`, run `make dtbs`
for an hour, and ship a kernel with no overlay. nothing in the build
output mentions it. the `*.dtbo` file just isn't there.

i lost a weekend to this.

the cause is two-layered:

1. `kernel-devicetree/scripts/Makefile.lib` adds `dtb-y` to `always-y`
   but doesn't do the same for `dtbo-y`. registered, never built.
2. the zed x overlay dts uses `#ifdef BUILDOVERLAY` to conditionally
   emit the `/dts-v1/; /plugin/;` header. without `-DBUILDOVERLAY`,
   you get a malformed empty dtbo even if you trick the build into
   compiling it.
3. **AND**: dtc 1.5.x (what ubuntu 20.04 ships in the docker container)
   reports false-positive `duplicate_label` errors on overlay dts files.
   the kernel's in-tree `dtc` handles this; the host system `dtc`
   needs `-f` to force.

so we bypass the whole nvidia mess and compile the dtbo directly:

```bash
DTC_BIN="$SOURCE/kernel/kernel-jammy-src/scripts/dtc/dtc"
HW_NV="$SOURCE/hardware/nvidia"
ZED_DTS="$HW_NV/t23x/nv-public/tegra234-p3768-camera-zedlink-mono-sl-overlay.dts"
ZED_DTBO="$L4T/kernel/dtb/tegra234-p3768-camera-zedlink-mono-sl-overlay.dtbo"

cpp -E \
    -DBUILDOVERLAY \
    -DLINUX_VERSION=600 \
    -DTEGRA_HOST1X_DT_VERSION=2 \
    -x assembler-with-cpp -nostdinc \
    -I"$HW_NV/t23x/nv-public" \
    -I"$HW_NV/t23x/nv-public/include/kernel" \
    -I"$HW_NV/t23x/nv-public/include/nvidia-oot" \
    -I"$HW_NV/t23x/nv-public/include/platforms" \
    -I"$HW_NV/tegra/nv-public" \
    -I"$SOURCE/kernel/kernel-jammy-src/include" \
    -o /tmp/zedlink-mono.dts.tmp \
    "$ZED_DTS"

# -@ enables the __symbols__ node for overlay label resolution.
# -f suppresses the dtc 1.5.x false-positive errors.
$DTC_BIN -@ -f -I dts -O dtb -o "$ZED_DTBO" /tmp/zedlink-mono.dts.tmp
```

`scripts/02_build_kernel.sh:57-83` has the actual code. **always
verify the dtbo exists after build**:

```bash
ls -lh latest_jetson/Linux_for_Tegra/kernel/dtb/tegra234-p3768-camera-zedlink-mono-sl-overlay.dtbo
# should be ~79 kb. if it's 0 bytes or missing, your dtbo didn't compile.
```

`scripts/pre_flash_audit.sh` checks this; don't flash without it.

### linux-headers-*.deb — the secret weapon

at the end of phase 2 we run `make bindeb-pkg` to produce a
`linux-headers-5.15.x-tegra_*.deb` and stash it under
`Linux_for_Tegra/staging/kernel-headers/`. phase 3 bakes it into
`/opt/kernel-headers/` on the rootfs, and `jetson_first_boot.sh`
`dpkg -i`'s it before any third-party installer runs. result:
`/usr/src/linux-headers-$(uname -r)/` is populated, and dkms-based
installers (zed sdk, voyager) can rebuild against our exact kernel.

without this, every dkms install is a vermagic mismatch waiting to
happen.

### vermagic — the deep dive

i need to spend a full section on this because it's the single biggest
source of "why doesn't my driver load" pain on a custom rt kernel.

#### what vermagic actually is

every `.ko` carries a 64-byte string in its `__module_vermagic`
section. the format is approximately:

```
<UTS_RELEASE> SMP <preempt_mode> mod_unload <arch>
```

for our kernel:

```
5.15.148-tegra SMP preempt_rt mod_unload aarch64
```

when `insmod` loads a `.ko`, the kernel reads the embedded vermagic
and compares it byte-for-byte to its own. **any difference → "Invalid
module format". no retry, no useful error message.**

the inputs that change vermagic:

- `UTS_RELEASE` = `KERNELVERSION + LOCALVERSION` — our `-tegra`
  is the anchor
- preempt mode — `preempt_rt` for us, `preempt` for stock nvidia
- `MODULE_UNLOAD` — `y` for us
- arch — `aarch64`

`CONFIG_MODVERSIONS=y` adds a stricter check on top: each symbol the
module imports must have a crc matching the kernel's exported-symbol
crc. mismatch = rejection even if vermagic matches.

#### why this hits us hardest

three knobs combined make our vermagic uniquely incompatible with
anything anyone ships:

1. **`LOCALVERSION=-tegra`** — stock l4t doesn't have this
2. **`CONFIG_PREEMPT_RT=y`** — stock l4t is `preempt`, not `preempt_rt`
3. **bootlin gcc 11.3** — different toolchain fingerprint than
   nvidia's build

so:

| where the .ko comes from | will it load on our kernel? |
|---|---|
| stock `nvidia-l4t-kernel-modules.deb` | **NO** (preempt vs preempt_rt) |
| stereolabs zed x deb | **NO** (built against stock nvidia kernel) |
| pre-built axelera metis from a community link | **NO** |
| voyager sdk's `install.sh --driver` (dkms rebuild on target) | **CONDITIONAL** — only if our headers .deb is installed first |
| our phase 2 build (kernel + in-tree drivers) | **YES** (single source of truth) |

#### the three-layer defense

1. **in-tree where possible**. metis driver lives at
   `drivers/misc/axelera/`; zed x lives at `drivers/media/i2c/zedx/`.
   the kernel's own `make modules` builds both with the same toolchain
   + headers + module.symvers as the kernel. vermagic match guaranteed.
2. **ship matching headers .deb** in the rootfs at `/opt/kernel-headers/`
   and dpkg-i it at first-boot. third-party installers find headers
   under `/usr/src/linux-headers-$(uname -r)/` and dkms succeeds.
3. **gates that hard-fail**. `verify_vermagic.sh --build-tree` runs at
   end of phase 2. `pre_flash_audit.sh` gates flashing. `verify_tuning.sh`
   on the live target walks every `.ko` under `/lib/modules/$(uname -r)/`
   and reports any mismatch.

#### things people will tell you to do that are wrong

- **"just `insmod --force`"** — no. our kernel has
  `CONFIG_MODULE_FORCE_LOAD` not set, so the kernel doesn't even
  accept the flag. but even on a kernel that did, force-loading a
  vermagic-mismatched module corrupts kernel memory in non-obvious
  ways and you'll crash 20 minutes later in unrelated code.
- **"just `apt install nvidia-l4t-kernel-modules`"** — no. our
  first-boot script holds these packages and pins them to
  `Pin-Priority: -1`. for good reason. they're built against stock
  nvidia kernel.
- **"just rebuild dkms"** — only safe if you have our matching
  headers .deb installed first. otherwise dkms picks up whatever's at
  `/usr/src/linux-headers-$(uname -r)/` and that's what stock
  nvidia-l4t-kernel-headers ships, which is the wrong vermagic.

if your `lsmod | grep <some-driver>` is empty after first boot,
**always** check vermagic before doing anything else:

```bash
modinfo /lib/modules/$(uname -r)/.../driver.ko | grep vermagic
uname -r
# the vermagic must contain uname -r byte-for-byte.
```

---

## part 3 — drivers

### axelera metis: in-tree, not oot

the axelera bring-up guide treats metis as an out-of-tree (oot)
module — clone the driver tree, run its `make`, hope vermagic matches.
that path is fragile under preempt_rt because oot makefiles often
ignore your `CROSS_COMPILE` env or pick up host headers.

instead, we promote metis to in-tree. phase 1 generates a thin
kconfig + kbuild shim under `drivers/misc/axelera/`:

```
drivers/misc/axelera/
├── Kconfig                   ← defines CONFIG_AXELERA_METIS
├── Makefile                  ← obj-$(CONFIG_AXELERA_METIS) += metis-wrapper/
├── metis-src                 ← symlink → source/axelera/axelera-driver/
└── metis-wrapper/
    └── Makefile              ← include $(VENDOR_DIR)/Makefile
```

the symlink keeps the canonical vendor source under `source/axelera/`,
where any vendor patches we apply still flow through. the wrapper
makefile delegates to the vendor's makefile but runs it under the
kernel's own build environment (`KERNELRELEASE`, `srctree`,
`CROSS_COMPILE`).

phase 1 also wires `drivers/misc/Kconfig` and `drivers/misc/Makefile`:

```
# drivers/misc/Kconfig (insert before final endmenu)
source "drivers/misc/axelera/Kconfig"

# drivers/misc/Makefile (append)
obj-$(CONFIG_AXELERA_METIS) += axelera/
```

with `CONFIG_AXELERA_METIS=m` in defconfig, `make modules` produces
`metis.ko` automatically with the kernel's vermagic.

#### axelera pci vendor id

**Note:** the axelera metis pci vendor:device id is
**`1f9d:1100`**. for **months** i had `1d60` everywhere — in
brownout-guard, in verify scripts, in dmesg-grep filters. `lspci -d :1d60:`
silently returned nothing because nothing on the bus had vendor `1d60`.
i thought metis was ghosting; actually my queries weren't matching.
confirmed against an [axelera community
thread](https://community.axelera.ai/metis-pcie-7/axelera-metis-pcie-ai-accelerator-not-recognized-by-lspci-145).
`lspci -d 1f9d:` is the right query.

while we're on it: the metis m.2 form factor is **m.2 2280** (full
length), pcie **gen3 x4** — not 2230 / gen4 x2 as some secondary
sources suggest. confirmed against the
[axelera datasheet](https://axelera.ai/hubfs/Axelera_February2025/pdfs/axelera-ai-m2-ai-edge-accelerator-module.pdf).
plan your carrier accordingly.

#### udev rules

`72-axelera.rules` is staged into `rootfs/etc/udev/rules.d/` by phase
1. it names the metis device node predictably so the runtime can find
it without scanning `/dev/pci*`.

#### voyager sdk userspace

new in 1.6: the voyager sdk ships as **pip wheels**, not as
`install.sh --driver`. the legacy install path still exists but the
wheels are the recommended route on a vermagic-clean kernel:

```bash
pip install axelera-rt axelera-devkit \
    --extra-index-url https://software.axelera.ai/artifactory/api/pypi/axelera-pypi/simple
```

**Note:** the url **must** include `/api/pypi/<repo>/simple`
— pip's index api requires that path. the bare
`/artifactory/axelera-pypi/` we used originally returns 404.

`jetson_first_boot.sh` runs this in `/opt/av-env` (a python venv we
own) and pins `numpy<2.0.0` because voyager has not yet certified
numpy 2.x as of 1.6.

### zed x stereo + zed link mono

the in-tree shim mirrors the metis approach but at
`drivers/media/i2c/zedx/`:

```
drivers/media/i2c/zedx/
├── Kconfig
├── Makefile
├── zedx-src                  ← symlink → source/stereolabs/
└── zedx-wrapper/
    └── Makefile
```

`Kconfig` exposes:

```
CONFIG_VIDEO_ZEDX=m              # top-level
CONFIG_VIDEO_ZEDX_AR0234=m       # onsemi AR0234 sensor
CONFIG_VIDEO_ZEDX_IMX678=m       # Sony IMX678 sensor
CONFIG_SL_DESER_MAX9296=m        # ZED Link Mono deserializer (REQUIRED)
CONFIG_SL_DESER_MAX96712=n       # ZED Link Duo/Quad deserializer (DO NOT enable)
```

**this only works if you have stereolabs source.** see part 1 for the
rant about stereolabs not publishing the source publicly. without
source, the in-tree shim is harmless — it just produces nothing
because there's nothing under `zedx-src/`.

#### isp calibrations

`zedx-driver/ISP/*.isp` files are baked into
`/var/nvidia/nvcam/settings/` by phase 3. nvidia's `nvcam` daemon
loads them at boot to tune the isp pipeline (exposure, white balance,
lens shading) for the specific sensor. without these, the camera
still works but the colors are off and slam will be unhappy.

#### the dtbo

the zed x overlay registers the camera with the tegra device tree.
`tegra234-p3768-camera-zedlink-mono-sl-overlay.dtbo` is compiled by
phase 2 (the cpp + dtc workaround above) and registered in
`extlinux.conf`:

```
APPEND ${cbootargs} ...
OVERLAYS /boot/tegra234-p3768-camera-zedlink-mono-sl-overlay.dtbo
```

cboot applies the overlay during boot. without it, the camera doesn't
appear in `/dev/video*` even if the driver loads.

#### testing the camera

```bash
# v4l2 enumeration
v4l2-ctl --list-devices

# 5-second nvmm capture (bypasses memcpy)
sudo gst-launch-1.0 -v nvarguscamerasrc num-buffers=150 ! \
    'video/x-raw(memory:NVMM),width=1920,height=1080,framerate=30/1' ! \
    fakesink
```

if `v4l2-ctl --list-devices` shows nothing for zed x: the overlay
didn't apply. check `/boot/extlinux/extlinux.conf` for the `OVERLAYS`
line and that the `.dtbo` exists in `/boot/`.

#### zed sdk userspace

the zed sdk `.run` installer is a closed-source binary. it installs
the userspace libs to `/usr/local/zed/`. **it tries to dkms-install
`sl_zedx.ko` against the running kernel.** if our headers .deb is
present, dkms will succeed (with a vermagic-correct module that ends
up shadowing our in-tree one — harmless). if not, dkms fails.

**`skip_drivers` does not exist.** the documented flags are `silent`,
`runtime_only`, `skip_python`, `skip_cuda`, `skip_tools`,
`skip_od_module`, `skip_hub`, `nvpmodel=0`. passing `skip_drivers`
is silently ignored and the dkms path still runs.
`scripts/install_zed_sdk.sh` uses the correct flags:

```bash
"$INSTALLER" -- silent runtime_only skip_python skip_cuda skip_tools \
                  skip_od_module skip_hub nvpmodel=0
```

then we install pyzed into our venv via the official helper:

```bash
/opt/av-env/bin/python /usr/local/zed/get_python_api.py
```

### nvme

nothing exotic on the nvme side — l4t's flash flow handles it. the
kernel configs above (`NVME_MULTIPATH`, `NVME_HWMON`, `BLK_MQ_PCI`)
give us multipath, temperature monitoring, and per-cpu queue
distribution.

we DO add a btrfs data partition for black-box recordings. `phase 7`'s
`install_data_partition.sh` does this:

1. detect free space at the end of `/dev/nvme0n1`
2. if ≥100 gb free: `parted` adds a btrfs partition there
3. if not: 200gb sparse loop file at `/opt/jetson-av-data.btrfs`
4. mount with `compress=zstd:3,noatime,space_cache=v2,autodefrag`
5. install a `jetson-av-btrfs-scrub.timer` that runs `btrfs scrub`
   weekly (sunday 03:00 + 2h randomized delay)

what you get on a single drive:

- block-level crc32c bit-rot detection (silent corruption → i/o error)
- ~2x compression on jsonl event logs and ros 2 bag files
- atomic snapshots per flight (btrfs subvolume)
- weekly scrub catches bad blocks before mid-mission

what you don't get yet: cross-drive redundancy. when you add a second
nvme, the same script supports `DATA_RAID=1` for in-place btrfs raid1
conversion (preserves data; mirrors data + metadata; self-heals on
scrub).

#### nvme write cache policy

`/etc/jetson-av/storage.conf`:

```sh
NVME_VWC=off    # off=durable | on=fast | skip=device default
```

`off` flips the volatile write cache via
`nvme set-feature -f 6 -v 0`. costs ~2x sequential write throughput;
gains data durability across sudden power-cut. **for black-box mode
you want this off.**

a udev rule applies the policy on every nvme enumeration so it
survives reboots (vwc setting is volatile in nvme).

---

## part 4 — bake, flash, first boot

### phase 3: bake

```bash
make bake
```

what `scripts/03_bake_rootfs.sh` does:

- copy voyager-sdk into `/home/j/voyager-sdk` on the rootfs
- copy axelera udev rules into `rootfs/etc/udev/rules.d/`
- copy zed x isp `.isp` files into `/var/nvidia/nvcam/settings/`
- copy `BUILD_MANIFEST.json` (commit, vermagic, toolchain, defconfig
  hash) into `/etc/jetson-av-build.json` so every flashed device can
  identify its build via `jetson-av-version` cli
- copy `/usr/local/bin/jetson-av-version` cli
- copy first-boot + per-boot rt-tune + verify scripts
- install systemd services (`jetson-first-boot.service`,
  `jetson-rt-tune.service`, etc.)
- copy `linux-headers-*.deb` into `/opt/kernel-headers/`
- copy zed sdk `.run` installer + wrapper into `/opt/zed-sdk/` (if
  present)
- copy phase 5 (av stack) + phase 7 (resilience) scripts into
  `/home/j/phase5/` and `/home/j/phase7/`
- inject rt boot args into `extlinux.conf`:
  `nohz_full=1-5 isolcpus=1-5 rcu_nocbs=1-5 irqaffinity=0 efi=noruntime pcie_aspm=off cma=2G`
- register the zed x dtbo overlay

### the audit gate

```bash
make audit
```

`scripts/pre_flash_audit.sh` is a hard fail-or-pass gate. it walks:

- kernel image is `-tegra` (string in the binary)
- `PREEMPT_RT` strings present
- `CONFIG_DMABUF_HEAPS=y` either in the binary or the staged defconfig
- `LINK_WAIT_MAX_RETRIES=100` in the source header
- `extlinux.conf` has `isolcpus=1-5`, `nohz_full=1-5`, `cma=2G`
- zed x overlay `.dtbo` exists in `rootfs/boot/`
- vermagic is consistent across every `.ko` in `rootfs/lib/modules/`

exit 0 = green; exit 1 = at least one failure.
**don't flash on failure.** this gate has caught me from shipping a
broken image at least three times.

### phase 4: flash

put the jetson into recovery mode (short rec + gnd, plug usb-c into
the **rear** motherboard port — not a hub), then:

```bash
make flash
```

what happens:

```bash
sudo ./tools/l4t_flash_prerequisites.sh
sudo ./apply_binaries.sh

# auto-detect the apx device (USB ID 0955:7023) for 60s, fall back to prompt
# rndis udev rule (so the gadget shows up as usb0)
# then:
sudo ./tools/kernel_flash/l4t_initrd_flash.sh \
    --external-device nvme0n1p1 \
    -c tools/kernel_flash/flash_l4t_t234_nvme.xml \
    -p "-c bootloader/generic/cfg/flash_t234_qspi.xml" \
    --showlogs --network usb0 \
    jetson-orin-nano-devkit internal
```

**Board target:** the correct target for orin nx 16gb (P3767 module on
a P3509-class carrier) is `jetson-orin-nano-devkit` (aliases
`p3509-a02+p3767-0000.conf`). **do not use `jetson-orin-nano-devkit-super`**
— that is a power-table variant for the orin NANO devkit, not orin nx.

if you flash with `-super` on orin nx 16gb, the flash itself
"succeeds" but the device boots with the wrong power profile and you
get ~30% reduced cpu/gpu clocks plus weird thermal behavior. it's the
hardest kind of bug to diagnose because nothing fails loud.

`make doctor` validates `TARGET_BOARD` against the extracted l4t tree
and lists alternatives if it can't find your value.

### first boot

after flash:
1. power off the jetson
2. **remove the recovery jumper** (don't leave the rec/gnd short in
   place)
3. power on

`jetson-first-boot.service` runs (~3-5 min). what it does, in order:

1. **`personalize_first_boot.sh`**: regenerate ssh host keys, set
   hostname (from `/etc/jetson-av-fleet/device.conf` if staged, else
   from mac), optionally write systemd-networkd file for static ip.
   **Note:** i shipped 5 jetsons without this once. every one
   of them booted with **identical ssh host keys** (baked into the
   stereolabs-flavored rootfs). the moment they were on the same
   network, ssh "host key changed" warnings cascaded everywhere.
   personalize first, always.
2. **apt-mark hold + Pin-Priority -1** for all `nvidia-l4t-kernel*`
   and bootloader packages. **Note:** `apt-mark hold` alone
   is not enough. `apt install nvidia-l4t-kernel-modules=<version>`
   overrides hold. only `Pin-Priority: -1` in
   `/etc/apt/preferences.d/` actually rejects the package.
3. **install our `linux-headers-*.deb`** so dkms-based installers find
   matching headers under `/usr/src/linux-headers-$(uname -r)/`.
4. **build /opt/av-env venv** with `numpy<2.0.0`, pytorch 2.7 from
   jetson wheels, voyager sdk pip wheels.
5. **run zed sdk installer** (if `.run` is staged at `/opt/zed-sdk/`)
   in `silent runtime_only skip_python skip_cuda skip_tools
   skip_od_module skip_hub nvpmodel=0` mode.
6. **inject rt boot args** into `extlinux.conf` (idempotent — only
   adds if not present).
7. **run phase 7 (resilience) installer** — see below.
8. **run phase 5 (av stack) installer** — see part 5.

### phase 7 — platform hardening

every meaningful piece runs as a systemd service so it survives
restart-after-failure scenarios. installed by
`scripts/install_uav_phase7.sh`:

| service | what it does |
|---|---|
| systemd hardware watchdog | `RuntimeWatchdogSec=30s` — if pid1 dies, hardware reboots in 2 min |
| persistent journald | `Storage=persistent`, `SystemMaxUse=2G`, so previous boots survive |
| `tmp.mount` | `/tmp` on tmpfs to avoid ssd wear over months of operation |
| logrotate AV rules | bounded `/var/log/syslog,auth,kern`; 30-day retention for `/var/log/jetson-av/` |
| chrony ntp | `makestep 1.0 3` for sharp time corrections; ptp guidance for gps-pps |
| ssh hardening | key-only, no root, idle-disconnect |
| ufw firewall | deny incoming, allow ssh + dds (`7400:7500/udp`) + mavlink (`14550/udp`) |
| smartmontools | nvme wear/temp monitoring |
| `jetson-blackbox.service` | per-flight `/var/log/jetson-av/flights/<ts>/` directory with ros bag, jsonl event log, sha256 hash chain |
| `jetson-brownout-guard.service` | caps metis at 18W via `axdevice`, polls `lspci -d 1f9d:` every 5s, runs pcie rescan on disappearance |
| `jetson-av-pcie-aer-monitor.service` | polls `aer_dev_*` counters every 5s, emits black-box events on increases |
| `jetson-mavlink-watchdog.service` | watches `/mavros/state` heartbeat, sends `SIGUSR1` to black-box on loss |

all of them write events into `/var/run/jetson-av-events` (named pipe)
which the black-box recorder drains into `events.jsonl` with hash
chain. post-flight forensic review can correlate "metis disappeared at
T+1247s" with "aer correctable +3 at T+1245s" with "primary mavlink
heartbeat lost at T+1246s" — full timeline of what happened.

### phase 5 — av application stack

`scripts/install_av_phase5.sh` does:

1. **`build_opencv_cuda.sh`**: clones opencv 4.10 + opencv_contrib,
   builds with `-DWITH_CUDA=ON -DWITH_CUDNN=ON -DOPENCV_DNN_CUDA=ON
   -DCUDA_ARCH_BIN=8.7 -DWITH_GSTREAMER=ON -DWITH_NVCUVID=ON
   -DPYTHON3_EXECUTABLE=/opt/av-env/bin/python`. caches the result as
   a `.deb` at `/opt/opencv-cache/` so re-flashing N units doesn't
   rebuild N times — units 2..N pull from the cache.

   **Note:** `apt install python3-opencv` ships **without
   cuda**. every `cv2.cuda.*` call returns 0 cuda devices.
   `cv2.dnn.setPreferableTarget(cv2.dnn.DNN_TARGET_CUDA)` silently
   runs on cpu. for RT vision workloads that's a 10-30x slowdown. you must
   build from source.

2. **`verify_opengl_cuda.sh`**: confirms libegl_nvidia, glxinfo
   renderer, nvcc, cuda probe binary, trtexec, vpi, libcudnn8,
   `cv2.cuda.getCudaEnabledDeviceCount() > 0`.

3. **`install_av_stack.sh`**: ros 2 humble + isaac ros (nitros,
   image_pipeline, visual_slam (cuvslam), nvblox, object_detection)
   + nav2 + mavros.

4. **install jetson-av-mission.service** — boot-time mission graph,
   not auto-started (operator reviews `/etc/jetson-av/mission.conf`
   before launching).

### per-boot rt tune

`jetson-rt-tune.service` runs **every** boot (these settings are
volatile by hardware design):

```bash
nvpmodel -m $NVPMODEL_MODE        # default 4=MAXN_SUPER
jetson_clocks                     # lock all clocks to max
echo $LOCK_CPU_GOV > .../scaling_governor   # default performance
echo $GPU_TARGET > /sys/class/devfreq/17000000.gpu/{min,max}_freq
echo $EMC_MAX > /sys/kernel/debug/bpmp/debug/clk/emc/rate
echo $FAN_PWM > /sys/devices/platform/pwm-fan/...

# scheduler tuning
sysctl -qw kernel.sched_min_granularity_ns=100000
sysctl -qw kernel.sched_wakeup_granularity_ns=100000
sysctl -qw kernel.sched_migration_cost_ns=50000

# transparent hugepages
echo always > /sys/kernel/mm/transparent_hugepage/enabled
echo madvise > /sys/kernel/mm/transparent_hugepage/defrag

# pcie always-on
for f in /sys/bus/pci/devices/*/power/control; do echo on > $f; done

# irq pinning
# - core 0: os, nvme, watchdog
# - core 1: metis irqs + inference
# - core 2: zed x csi/vi
# - cores 3-5: slam, nav2, blackbox
# all other Tegra IRQs (host1x, nvenc, nvdec, isp, mipi-cal, vic, nvgpu)
# default to mask 0xC1 (cores 0, 6, 7) so they don't land on isolated cores

# fair-queue qdisc on primary nic for dds multicast
tc qdisc replace dev $PRIMARY_IF root fq

# oom shield for axelera runtime
echo -1000 > /proc/$AXELERA_PID/oom_score_adj
```

**Note:** the gpu devfreq path on r36.x is
`/sys/class/devfreq/17000000.gpu`. **on r35.x it was
`/sys/class/devfreq/17000000.ga10b`.** my script had `.ga10b` for
months. on r36.5 the path doesn't exist; the gpu lock silently
no-op'd; gpu was running at scaled-down clocks under load. the
current script tries `.gpu` first, falls back to `.ga10b` for r35.x
support.

`/etc/jetson-av/power.conf` is a single source of truth read by both
rt-tune and the brownout guard:

```sh
NVPMODEL_MODE=4
GPU_MAX_FREQ_HZ=        # empty=hw max; 800000000 to leave EMC bandwidth for Metis
EMC_FREQ_HZ=            # empty=hw max
LOCK_CPU_GOV=performance
FAN_PWM=255
AXELERA_POWER_LIMIT_W=18
```

reference budgets:

| profile | nvpmodel | metis cap | gpu | total typical | total peak |
|---|---|---|---|---|---|
| **default** | 4 (maxn_super 40w) | 18w | uncapped | ~45w | ~65w |
| conservative (smaller psu) | 1 (15w) | 15w | 800mhz cap | ~22w | ~33w |
| bench / wall-powered | 0 (maxn 25w) | 23w (no cap) | uncapped | ~38w | ~55w |

---

## part 5 — telemetry and the av stack

### mavlink router + iridium failover

architecture:

```
                   ┌────────────┐
   FCU (Pixhawk 6X)│ TELEM2 UART│  /dev/ttyTHS1 @ 921600
                   └─────┬──────┘
                         │
                         ▼
              ┌────────────────────────┐
              │    mavlink-router      │
              └────┬───────┬────────┬──┘
                   │       │        │
        ┌──────────┘       │        └─────────────┐
        ▼                  ▼                      ▼
   UDP :14550        TCP :5760             UDP :14540 (local)
   ┌───────────┐    ┌──────────┐          ┌───────────┐
   │ Doodle    │    │ Iridium  │          │  MAVROS   │
   │ Labs      │    │ SBD      │          │  (ROS 2)  │
   │ Helix     │    │ relay    │          └───────────┘
   │ → GCS     │    │ → modem  │
   └───────────┘    └──────────┘
                         │
                         ▼
                   /dev/ttyUSB0
                  RockBLOCK 9704
```

**UART:** the pixhawk 6x telem2 port is wired to
the jetson's uart1 internally, which linux exposes as
**`/dev/ttyTHS1`**. **`/dev/ttyTHS0` is the debug console.** my
original config had `/dev/ttyTHS0`; mavros opened it, "succeeded",
and got nothing because nothing was on the other end. verify with
`dmesg | grep ttyTHS` after first boot.

**RockBLOCK 9704 protocol:** the older rockblock
9602 / 9603 modems use the **at command set** (`AT+SBDWB`,
`AT+SBDIX`) over **cdc-acm** (`/dev/ttyACM0`). the **9704 is
different**:
- it uses **ftdi usb-serial** (`/dev/ttyUSB0`) — needs
  `CONFIG_USB_SERIAL_FTDI_SIO`, not `CONFIG_USB_ACM`
- it speaks **jspr** (json serial protocol for rest), **not at
  commands**
- the official client is `pip install rockblock9704` (rock7's sdk)

i had at-command code targeting `/dev/ttyACM0` for months. the 9704
ignored every byte i sent because they were the wrong protocol on the
wrong device node. silent failure: no errors, no responses, just no
sbd messages making it out.

the relay supports both via the `IRIDIUM_MODEL` knob:

```sh
# /etc/jetson-av/telemetry-failover.conf
IRIDIUM_MODEL=9704        # or 9603 for legacy
IRIDIUM_TTY=/dev/ttyUSB0  # or /dev/ttyACM0 for 9603
IRIDIUM_BAUD=230400       # or 19200 for 9603
SBD_INTERVAL_NORMAL=60    # seconds between SBD bursts when primary is OK
SBD_INTERVAL_DEGRADED=15  # when /run/jetson-av-link-state == "degraded"
```

the `jetson-av-link-monitor.service` watches `/mavros/state` for
GCS-side heartbeats and writes `/run/jetson-av-link-state` (`ok` or
`degraded`); the iridium relay reads it.

cost-aware: at 60s cadence over a 30-min flight at typical rock7
plans, that's ~$30/flight at degraded rate. tune intervals to budget.

### opencv with cuda

i covered the build above. for the application code that uses it,
this is the smoke test:

```python
import cv2
print('OpenCV:', cv2.__version__)
print('CUDA devices:', cv2.cuda.getCudaEnabledDeviceCount())
print('Has CUDA in build:', 'CUDA' in cv2.getBuildInformation())

# run yolo with dnn_cuda backend
net = cv2.dnn.readNet("/opt/jetson-av/models/yolo.onnx")
net.setPreferableBackend(cv2.dnn.DNN_BACKEND_CUDA)
net.setPreferableTarget(cv2.dnn.DNN_TARGET_CUDA_FP16)
```

if `cv2.cuda.getCudaEnabledDeviceCount()` is 0, opencv was rebuilt
without `-DWITH_CUDA=ON` somewhere. `cv2.getBuildInformation()` shows
the actual flags.

### ros 2 + isaac ros + nav2 + mavros

the full mission graph in `launch_av_mission.sh` (started by
`jetson-av-mission.service` after operator review):

| layer | component | compute | pinned to |
|---|---|---|---|
| camera | `zed_wrapper` | isp + nvmm | core 2 |
| object detection | `axelera.runtime` python | metis npu | core 1 |
| depth | zed sdk stereo | gpu (cuda) | core 2 (shared) |
| visual slam | `isaac_ros_visual_slam` (cuvslam) | gpu + cpu | cores 4-5 |
| 3d mapping | `isaac_ros_nvblox` | gpu | core 3 |
| planning | `nav2_bringup` (hybrid a* + dwb) | cpu | core 6 |
| fcu bridge | `mavros` | cpu + uart | core 7 |
| black-box | `jetson-blackbox` | cpu + nvenc | core 0 |

cpu pinning is enforced via `systemd-run --scope -p AllowedCPUs=…`.
cores 1-5 are kernel-isolated (boot args).

### axrun — for ad-hoc inference runs

`launch_av_mission.sh` does proper pinning at boot. for shell /
debug / oneshot runs, use the `axrun` wrapper:

```bash
# default: core 1, oom-shielded, no rt priority
axrun python detect_metis.py /path/to/yolo.ax

# slam profile
axrun --slam ros2 launch isaac_ros_visual_slam ...

# rt priority for hard-deadline loops
axrun --rt --cpu 1 ./hard_realtime_loop
```

without it, your interactive `python detect_metis.py` runs on whatever
core the scheduler picks, often a non-isolated one, and you get
±300µs jitter for no reason.

---

## part 6 — validation, fleet, golden-image

### the validation gauntlet

```bash
make verify
```

ssh's to the jetson and runs `verify_tuning.sh` which:

- **kernel identity** — `uname -r` ends in `-tegra`
- **cpu isolation** — `/sys/devices/system/cpu/isolated == 1-5`
- **tickless mode** — `nohz_full=1-5` in `/proc/cmdline`
- **cma reservation** — `CmaTotal > 1.9 gb`
- **vermagic on every loaded `.ko`** — walks
  `/lib/modules/$(uname -r)/` via `find -name '*.ko*'`, modinfo each,
  fail if any module's vermagic doesn't contain `$(uname -r)`
- **mission-critical drivers loaded** — based on
  `/etc/jetson-av/expectations.conf`:
  ```sh
  EXPECT_METIS=1
  EXPECT_ZED_X=1
  EXPECT_MAX9296=1
  ```
  loud red FAIL when expected and not loaded; silent pass when not
  expected (botany-only airframe sets `EXPECT_ZED_X=0`)
- **hardware presence** — `lspci -d 1f9d:`, `lsmod | grep`,
  `/dev/dma_heap/`
- **power mode** — `nvpmodel -q` reports MAXN
- **thermal** — no `/sys/class/thermal/cooling_device*/cur_state > 0`
- **rt jitter** — 10s `cyclictest` burst on core 1, max < 100µs
- **/opt/av-env** — `axelera.runtime` importable, `torch.cuda.is_available()`,
  `pyzed.sl` importable

exits 0 only on full green. perfect for ci or for `make ignite`
post-flash settle.

### fleet manufacturing

once you've validated one, you scale. two paths.

**path a — release tarballs** (base firmware, distribute pre-customization):

```bash
make release VERSION=v1.0.0
# → releases/release-v1.0.0.tar.gz + .sha256 + .manifest.json
# (+ .sig if GPG_KEY env var set)
```

self-contained: no docker, no source repo, no toolchain needed on
the flash station. just untar and `./scripts/flash_release.sh`.

per-device `fleet.csv`:

```csv
device_label,hostname,static_ip,notes
av-01,av-01,192.168.10.11,prototype unit
av-02,av-02,192.168.10.12,
av-03,av-03,,DHCP only
```

```bash
make flash-batch FLEET=fleet.csv
```

loops through, prompts operator to swap devices, records every result
in `fleet_log.csv`. continues past failures (`STRICT=0`) so one bad
unit doesn't kill the batch.

**path b — golden-image clone** (post-customization, bit-identical):

once you've installed your apps, models, and ros packages on one
jetson and validated everything works:

```bash
# golden jetson powered off + apx recovery mode
make clone-golden TAG=v1.0-bench-validated
# → golden-images/golden-v1.0-bench-validated-<timestamp>/
#    + golden.manifest.json + CHECKSUMS.sha256 + golden.manifest.sig

make list-goldens

# for each receiving jetson (in recovery mode each)
make flash-golden GOLDEN=golden-v1.0-bench-validated-<ts> DEVICE=av-07
```

uses nvidia's `tools/backup_restore/l4t_backup_partitions.sh`
(preferred) or `l4t_initrd_flash.sh --read` (fallback) to pull
partition images back, then `--use-backup-image` to redeploy.

each receiving jetson still runs `personalize_first_boot.sh` — unique
hostname + ssh host keys + optional static ip. **bit-identical bytes
at flash time, divergent identity at boot.** no host-key collisions.

### provenance

end-to-end auditable:

```
git_head → BUILD_MANIFEST.json → release.manifest.json
                                        ↓
                          flashed to golden
                                        ↓
                               on-device customization
                                        ↓
                  clone_golden → golden.manifest.json + CHECKSUMS + sig
                                        ↓
                          flashed to av-07 → fleet_log.csv row
```

every step has a manifest + sha256 + (optional) gpg signature.
`fleet_log.csv` traces back through every layer to the original git
commit.

---

## part 7 — troubleshooting catalog

symptom-first, in the order you're most likely to hit them.

### build / extract failures

| symptom | root cause | fix |
|---|---|---|
| `wget: 404 Not Found` on bootlin url | nvidia moved toolchain to `r36_release_v3.0/` | use the `v3.0` url, not `v5.0` (Dockerfile is fixed) |
| `cp -r ../zedx-driver/...: No such file or directory` | stereolabs repo doesn't exist publicly | get source via business agreement, or skip ZED X |
| `aarch64-buildroot-linux-gnu-gcc: command not found` | running phase 2 outside docker | `make docker-build` then `make build` |
| `No board config matches '$TARGET_BOARD'` (doctor) | wrong board target in `versions.env` | use `jetson-orin-nano-devkit` for Orin NX 16GB, NOT `-super` |
| dtbo missing in `/boot/` after build | nvidia silently skipped `dtbo-y` | `02_build_kernel.sh` direct-compile path; verify with `ls latest_jetson/Linux_for_Tegra/kernel/dtb/*-sl-overlay.dtbo` |
| `make audit` fails at "Module Vermagic" | partial vermagic drift | `make clean && make all` — never partial rebuild after kernel CONFIG change |
| `make build` fails at `bindeb-pkg` | missing `dpkg-dev`/`fakeroot` | `apt install dpkg-dev fakeroot` in docker image |
| `linux-headers-*.deb` not produced | bindeb-pkg failed (warning, not fail) | DKMS-based installers will fail on target; rebuild |

### flash failures

| symptom | root cause | fix |
|---|---|---|
| flash hangs at "Waiting for target to boot-up" | rndis gadget not enumerated on host | `lsusb -t` (no hub), `modprobe rndis_host`, autosuspend off |
| Error 3 / 202 | usb chain (hub, autosuspend, weak cable) | direct rear motherboard port, `echo -1 > /sys/module/usbcore/parameters/autosuspend` |
| ECID blank / device not in apx | jetson didn't enter recovery | power off, re-short rec+gnd, re-power |
| flash succeeds, no boot | wrong board target (`-super` vs no `-super`) | update `versions.env`, re-flash |
| flash succeeds, ssh "host key changed" warning on every device | personalize_first_boot didn't run / regenerate keys | check `/etc/jetson-av-personalized` exists; if not, run manually + reboot |

### vermagic / module loadability failures

| symptom | root cause | fix |
|---|---|---|
| `dmesg \| grep "Invalid module format"` | vermagic mismatch | identify the module, rebuild from clean tree |
| `lsmod \| grep <name>` empty but `.ko` is on disk | modprobe failed silently | `modinfo <ko> \| grep vermagic` vs `uname -r`; if mismatched, full rebuild |
| ZED SDK install fails to build sl_zedx.ko | linux-headers-*.deb not installed on target | `dpkg -i /opt/kernel-headers/linux-headers-*.deb` then re-run installer |
| Loaded modules look fine but driver behaves wrong | per-symbol CRC drift (CONFIG_MODVERSIONS) | rebuild from clean tree (force-load isn't allowed and shouldn't be) |
| First boot hangs forever | first-boot script crashed; no auto-reboot | `journalctl -u jetson-first-boot.service` from another login (or recovery) |

### hardware enumeration failures

| symptom | root cause | fix |
|---|---|---|
| `lspci -d 1f9d:` empty (Metis ghost) | LINK_WAIT_MAX_RETRIES too low for cold boot | the patch sets it to 100; verify in source, rebuild if not |
| `lspci \| grep axelera` empty but `lspci -d 1f9d:` works | older `lspci` doesn't have the vendor name in its db | use the vendor:device id form |
| `v4l2-ctl --list-devices` shows nothing for ZED X | dtbo overlay didn't apply | check `OVERLAYS` line in `extlinux.conf` and `.dtbo` exists in `/boot/` |
| ZED X frames appear but stereo depth is garbage | wrong deserializer (MAX96712 instead of MAX9296) | `01_extract_and_patch.sh` enforces both defconfig + Makefile sed |
| MAX9296 dmesg errors / no frames | ISP `.isp` calibration missing or for wrong sensor | check `/var/nvidia/nvcam/settings/`, verify sensor variant |
| Realtek WiFi not detected | RTW88_8822CE not built | check defconfig, `lsmod \| grep rtw88` |
| GPU devfreq operations silently fail | path is `.gpu` on R36.x, not `.ga10b` | `jetson_rt_tune.sh` probes both; older revisions only had `.ga10b` |

### runtime failures

| symptom | root cause | fix |
|---|---|---|
| cyclictest max latency > 1ms | RT boot args missing OR governor wrong | `cat /proc/cmdline` must contain `isolcpus=1-5 nohz_full=1-5 rcu_nocbs=1-5`; CPU governor must be `performance` |
| Performance tanks mid-mission | thermal throttling | `cat /sys/class/thermal/thermal_zone*/temp`; add active cooling |
| Inference latency too high | inference process not pinned | use `axrun` (or `systemd-run --scope -p AllowedCPUs=1`) |
| `cv2.cuda.getCudaEnabledDeviceCount() == 0` | OpenCV was apt-installed without CUDA | rebuild with `build_opencv_cuda.sh` |
| `glxinfo` reports `llvmpipe` | nvidia-l4t-3d-core missing | `apt install --reinstall nvidia-l4t-3d-core` |
| MAVROS connects but no telemetry | wrong `/dev/ttyTHS*` | TELEM2 is `/dev/ttyTHS1`; ttyTHS0 is debug console |
| RockBLOCK 9704 sends silent | wrong protocol (AT vs JSPR) | `IRIDIUM_MODEL=9704` + `pip install rockblock9704` |
| Voyager pip install 404 | URL missing `/api/pypi/<repo>/simple` suffix | fixed in `versions.env` and `jetson_first_boot.sh` |
| TPM HW random not feeding entropy pool | wrong CONFIG name (TPM_HW_RANDOM vs HW_RANDOM_TPM) | defconfig uses `HW_RANDOM_TPM=y` |
| nvblox memory growth | unbounded voxel map | set `max_distance` parameter in nvblox launch file |

---

## closing

### what this is and isn't

it's the artifact you need to actually ship a fleet of orin nx
16gb-based uavs with metis + zed x, doing real-time computer vision
without it falling apart on cold boot or a brownout. every magic value
in here was verified against vendor docs (the corrections list is in
`docs/VERIFICATION_REPORT.md` with source urls). every script passes
`bash -n`. every gate is reproducible.

it's not a beginner course. it's not a click-through tutorial. you
need to know what `make` does, you need to be willing to read kernel
defconfig, you need to be comfortable when `dmesg` is the only thing
between you and the answer.

if you want the click-through version, the original community
tutorial is still there and still works for "get something that boots
with metis visible".

### the repo

**https://github.com/silicondoritos/jetson-rt-stack** — apache 2.0.

contributions welcome. file an issue with the bug-report template;
include `make logs` output if you have it. the bar for prs is
documented in `CONTRIBUTING.md`.

### acknowledgments

- the **axelera team** (especially whoever wrote the bring-up guide
  and `axl-jetson.patch` 6+ months ago — none of this exists without
  that starting point).
- **nvidia jetson linux team** for l4t r36.5 + the public sources.
- **stereolabs** for the zed x platform.
- the **px4** / **ardupilot** / **mavros** / **mavlink-router**
  communities.
- the **linux kernel** + **preempt_rt** communities — every line of
  this is built on their work.
- **rock7** / **groundcontrol** for the rockblock 9704 sdk.
- the **isaac ros** team at nvidia.
- everyone who asked questions on the original Axelera community thread
  — those questions drove most of what's in this post.

### contact

open a github issue or discussion at [github.com/silicondoritos/jetson-rt-stack](https://github.com/silicondoritos/jetson-rt-stack).
paid consulting is not available — see CONTRIBUTING.md. the work is
open source so companies that need this can fork and grow their own
internal expertise. that's the point.

if you build something with this and it flies — say so in a github issue. seriously.
