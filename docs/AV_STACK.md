---
title: AV Stack
layout: default
description: "ROS 2 Humble + Isaac ROS + Nav2 — cuVSLAM visual SLAM, nvblox 3D occupancy, Hybrid A* path planning on the Jetson Orin NX 16GB."
nav_order: 25
---

# AV Application Stack — ROS 2 + Isaac ROS + cuVSLAM + nvblox + Nav2

**This is Layer 2 — optional.** The baseline image (Phases 1–4) is complete without this. Install Phase 5 when you have ZED X driver source and want the full vision + planning pipeline.

Camera → object detection (Metis NPU) + depth (GPU) + SLAM (cuVSLAM) → occupancy (nvblox) → planning (Nav2). Orchestrated by `jetson-av-mission.service`.

## Components

| Layer | Component | Compute | Pinned to |
|---|---|---|---|
| Camera | ZED X via `zed_wrapper` | ISP + NVMM buffers | core 2 |
| Object detection | Custom node calling `axelera.runtime` | Metis NPU | core 1 |
| Depth | ZED SDK stereo | GPU (CUDA) | core 2 (shared with camera) |
| Visual SLAM | `isaac_ros_visual_slam` (cuVSLAM) | GPU + CPU | cores 4–5 |
| 3D mapping | `isaac_ros_nvblox` | GPU | core 3 |
| Planning | `nav2_bringup` (Hybrid A* + DWB) | CPU | core 6 |
| Black-box | `jetson-blackbox.service` | CPU + NVENC | core 0 |
| Brownout guard | `jetson-brownout-guard.service` | CPU (low) | core 0 |

CPU pinning is enforced via `systemd-run --scope -p AllowedCPUs=…` in
`launch_av_mission.sh`. Cores 1–5 are the kernel's isolated set (see
`KERNEL_OPTIMIZATIONS.md` §1).

## Installation

`scripts/install_av_phase5.sh` is the single entry point. Runs at
first-boot OR manually:

```bash
sudo /home/j/phase5/install_av_phase5.sh
```

Steps (each pre/post-verified):

1. **Build/install OpenCV-CUDA** — see `docs/CUDA_LIBS.md`. Cached for
   re-use across N flashes.
2. **Verify CUDA/OpenGL** — `verify_opengl_cuda.sh`; warn-only here so a
   missing piece doesn't block downstream installs.
3. **Install ROS 2 Humble + Isaac ROS 3.x + Nav2** — adds
   `packages.ros.org` repo, installs `ros-humble-ros-base` plus
   `isaac_ros_visual_slam`, `isaac_ros_nvblox`, `navigation2`, `nav2_bringup`.
   **Note**: Isaac ROS 4.x (current) requires ROS 2 Jazzy on Ubuntu 24.04.
   Humble is compatible with Isaac ROS 3.x only. Source-build path is the
   safe default for Humble — apt coverage is partial.
4. **Install `jetson-av-mission.service`** — copies `launch_av_mission.sh`
   to `/usr/local/bin/`, writes `/etc/jetson-av/mission.conf`,
   registers the systemd unit. **Does NOT auto-start** — operator
   reviews config first.

After install, `/etc/profile.d/jetson-av-stack.sh` auto-sources
`/opt/ros/humble/setup.bash`, the Isaac ROS workspace (if source-built),
and the AV Python venv in every new shell.

## Mission config

`/etc/jetson-av/mission.conf` toggles each subsystem:

```sh
ENABLE_CAMERA=1
ENABLE_INFERENCE=1
ENABLE_SLAM=1
ENABLE_NVBLOX=1
ENABLE_NAV2=1
```

Useful patterns:

- **Bench testing**: `ENABLE_NAV2=0` — vision + inference pipeline only, no planning output.
- **Camera-only smoke**: `ENABLE_INFERENCE=0 ENABLE_SLAM=0
  ENABLE_NVBLOX=0` — see if the camera publishes at all.
- **Headless rehearsal**: `ENABLE_CAMERA=0` — replay a bag into
  the rest of the pipeline (modify `launch_av_mission.sh` to
  spawn a `ros2 bag play` node in place of the camera).

## Running the mission

```bash
# Dry-run (print what would launch, don't actually launch):
sudo /usr/local/bin/launch_av_mission.sh --dry-run

# Real launch:
sudo systemctl start jetson-av-mission.service

# Status:
systemctl status 'jetson-av-*'

# Logs:
journalctl -u jetson-av-mission.service -f

# Stop:
sudo systemctl stop jetson-av.slice    # stops all spawned scope units
sudo systemctl stop jetson-av-mission.service
```

`launch_av_mission.sh` writes a per-launch log to
`/var/log/jetson-av/mission-<timestamp>.log` so you can diff successive
launches.

## Inference pipeline (the byte path you actually care about)

```
ZED X (4K@30) ──MIPI──> Tegra ISP
                          │   debayer, white balance (NVMM buffer)
                          ▼
                  /dev/dma_heap/linux,cma  ←── shared zero-copy buffer
                          │
              ┌───────────┴────────────┐
              ▼                        ▼
       ZED SDK stereo                custom python node
       (GPU CUDA)                    (axelera.runtime)
              │                        │
       depth + odom                  YOLO bbox + class
              │                        │
              ▼                        ▼
    isaac_ros_visual_slam         /detections topic
       (cores 4-5, GPU)                │
              │                        │
       /vslam/odometry,                │
       /vslam/pose                     │
              │                        │
              └────┬───────────────────┘
                   ▼
         isaac_ros_nvblox  (3D voxel occupancy)
                   │
                   ▼
                 nav2  (Hybrid A* + DWB local planner)
                   │
                   ▼
                /cmd_vel
```

DDS QoS (FastDDS by default — `RMW_IMPLEMENTATION=rmw_fastrtps_cpp` set
in `/etc/profile.d/jetson-av-stack.sh`):

- High-rate camera topics: `best_effort + keep_last + depth=1`
- State topics (vslam pose): `reliable + keep_last + depth=5`
- Maps (nvblox occupancy): `reliable + transient_local`

NIC tuning happens in `jetson_rt_tune.sh` (`tc qdisc replace dev …
root fq`) — relevant when you have multiple Jetsons in the same DDS
domain.

## Models

Place pre-compiled models under `/opt/jetson-av/models/`:

```
/opt/jetson-av/models/
├── yolo_metis.ax              ← Axelera-compiled model
├── yolo_dla.engine            ← TensorRT-compiled fallback for DLA
└── seg_unet.engine            ← Segmentation on GPU
```

Bake them in at Phase 3 by adding to `03_bake_rootfs.sh`:

```bash
if [ -d "$REPO_ROOT/models" ]; then
    sudo mkdir -p "$ROOTFS/opt/jetson-av/models"
    sudo cp -r "$REPO_ROOT/models/"* "$ROOTFS/opt/jetson-av/models/"
fi
```

Compile YOLO for Metis with the Voyager SDK toolchain on a workstation
(not the Jetson) to keep the rootfs lean.

## Health checks per subsystem

Add to your monitoring stack or run manually:

```bash
# Camera publishing?
ros2 topic hz /zed/zed_node/rgb/image_rect_color

# Detector running?
ros2 topic hz /detections                    # should match camera Hz

# SLAM converged?
ros2 topic echo /vslam/pose --once           # non-zero pose

# Map building?
ros2 topic hz /nvblox/static_occupancy

# Planner running?
ros2 service list | grep -i nav2

# Black-box recording?
ls /var/log/jetson-av/flights/$(ls -t /var/log/jetson-av/flights | head -1)/bag/
```

## Troubleshooting

### `ros2 launch` fails with "package not found"

The stack environment didn't get sourced. Open a fresh shell or:

```bash
source /etc/profile.d/jetson-av-stack.sh
ros2 pkg list | grep <package>
```

### Mission service won't start

```bash
journalctl -u jetson-av-mission.service -n 50
sudo /usr/local/bin/launch_av_mission.sh --dry-run    # see what it would do
```

Most common cause: a referenced ROS package isn't installed. The
launcher prints a `WARN: ... not installed` line for each missing
component and skips it.

### High latency / drops in DDS

The `jetson_first_boot.sh` already tuned UDP buffers (`net.core.rmem_max`
to 2 GB). Check:

```bash
sudo sysctl net.core.rmem_max
sudo sysctl net.core.wmem_max
```

If they're back to defaults, re-run `sysctl -p`.

### Inference latency too high

Verify Metis is the actual target:

```bash
/opt/av-env/bin/python -c "
import axelera.runtime as ax
dev = ax.Device.connect()
print('device:', dev.info)
print('queue:', dev.queue_depth)
"
```

If `axelera.runtime` falls back to CPU, the kernel module isn't loaded
or the udev rule is missing. See `docs/DRIVERS.md` §3.6.

### nvblox memory growth

Voxel maps grow without bound. Set a max bound in your nvblox launch
file (`max_distance` parameter) or restart the service periodically
during long flights.

## Future work

- **Pre-compile mission models at bake time** — currently a manual step.
- **Per-mission config presets** — `mission-bench.conf`, `mission-flight.conf`,
  symlink `/etc/jetson-av/mission.conf` to the active one.
- **DeepStream multi-stream** — for surveying with N cameras feeding one
  pipeline.
