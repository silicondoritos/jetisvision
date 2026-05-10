---
title: CUDA Libraries
layout: default
description: "OpenCV-CUDA build from source, OpenGL/EGL/GLES, TensorRT, and VPI setup against L4T CUDA 12.6 on Jetson Orin NX 16GB."
nav_order: 26
---

# CUDA Userspace — OpenCV, OpenGL, EGL, TensorRT, VPI

Stock JetPack ships these libraries without CUDA / NVIDIA backends enabled. Below: the gap, the fix, the verification.

## The problem

| Library | Stock state | Symptom |
|---|---|---|
| `python3-opencv` (apt) | No CUDA, no cuDNN, no GStreamer | `cv2.cuda.getCudaEnabledDeviceCount() == 0`; DNN runs on CPU |
| `libGL.so` / `libEGL.so` | Mesa software path | OpenGL renderer is "llvmpipe", no GPU offload |
| TensorRT | Installed but unused | Models compile but never get exercised |
| VPI 3.x | Installed but unused | PVA / ISP backends never selected |
| cuDNN | Installed but version float | OpenCV linked against wrong cuDNN soname → import error |

### What this build provides

| Detail | Value |
|---|---|
| OpenCV version | **4.10.0** (pinned via `OPENCV_VERSION` env) |
| CUDA version | 12.6 (L4T R36.5 system CUDA; do not pip-install a different version) |
| cuDNN | libcudnn9 — cuDNN 9.3 (L4T R36.5 / JetPack 6.2.x; verify: `dpkg -l \| grep libcudnn9-cuda-12`) |
| CUDA arch | `CUDA_ARCH_BIN=8.7` (sm_87 — Orin NX / Nano Ampere GPU) |
| PTX | none (`CUDA_ARCH_PTX=""`) — faster startup, target-locked binary |
| Build location | on-device or cross-compiled; `build_opencv_cuda.sh` runs on the Jetson |
| Build time | ~45–60 min on Orin NX (on-device, `JOBS=$(nproc)`) |
| Cache | `.deb` written to `/opt/opencv-cache/`; units 2–N install in seconds |

The CUDA arch flag `8.7` is verified for Orin NX / Nano (GA10B / Ampere) — see [Verification Report]({{ '/VERIFICATION_REPORT' | relative_url }}) §1.6. Use `8.6` for AGX Orin (GA10x), `7.2` for Xavier NX (Volta).

The result: vision code that should run on the Ampere GPU runs on the
A78AE CPU at 10–30× the latency. Catastrophic for real-time applications
perception.

## The fix — three scripts

### `scripts/build_opencv_cuda.sh`

Builds OpenCV from source with the right CMake flags and installs to
`/usr/local`. Caches the result as a `.deb` at `/opt/opencv-cache/` so
re-flashing N units doesn't rebuild OpenCV N times — units 2..N pull
from the cache.

CMake flags that matter:

```
-D WITH_CUDA=ON
-D WITH_CUDNN=ON
-D OPENCV_DNN_CUDA=ON
-D ENABLE_FAST_MATH=ON
-D CUDA_FAST_MATH=ON
-D WITH_CUBLAS=ON
-D CUDA_ARCH_BIN=8.7         ← Orin = sm_87
-D CUDA_ARCH_PTX=""          ← no PTX (faster startup, target-locked binary)
-D WITH_GSTREAMER=ON
-D WITH_NVCUVID=ON           ← GPU video decode
-D WITH_FFMPEG=ON
-D WITH_OPENGL=ON
-D BUILD_opencv_python3=ON
-D PYTHON3_EXECUTABLE=/opt/av-env/bin/python    ← installs into our venv
-D OPENCV_GENERATE_PKGCONFIG=ON
-D OPENCV_ENABLE_NONFREE=ON
```

Build time: ~45–60 min on Orin. First flash takes the hit; subsequent
flashes pull the `.deb` and install in seconds.

Override knobs (env):

```bash
OPENCV_VERSION=4.10.0    # default
CUDA_ARCH_BIN=8.7        # 8.7 for Orin; 8.6 for AGX Orin; 7.2 for Xavier NX
JOBS=6                   # default $(nproc)
WORK_DIR=/var/tmp/opencv-build
CACHE_DIR=/opt/opencv-cache
```

### `scripts/verify_opengl_cuda.sh`

Read-only verifier that confirms the entire CUDA / OpenGL / GLES /
TensorRT / VPI / cuDNN / OpenCV stack is wired up correctly. Useful
both at first-boot and as part of `make verify`.

Checks (all pre/post-gated via the verify framework):

| Check | What it confirms |
|---|---|
| `libEGL_nvidia.so.0` etc | NVIDIA EGL/GLES libs installed |
| `eglinfo` | EGL display reports NVIDIA, not Mesa |
| `glxinfo` renderer | OpenGL renderer is NVIDIA / Tegra / Ampere |
| `nvcc --version` | CUDA toolkit installed |
| `nvidia-smi` or Tegra devfreq | GPU detectable |
| Tiny CUDA probe binary | nvcc compiles, binary runs, reports SM 8.7 |
| `trtexec --help` | TensorRT runtime present |
| `pkg-config vpi` | VPI installed |
| `libcudnn8` | cuDNN present |
| `cv2.cuda.getCudaEnabledDeviceCount() > 0` | OpenCV-CUDA active |
| `cv2.getBuildInformation()` contains "CUDA" | Build wasn't faked |

### `scripts/install_av_phase5.sh`

Orchestrator that runs:

1. `build_opencv_cuda.sh` (or pulls from cache)
2. `verify_opengl_cuda.sh`
3. `install_av_stack.sh` (ROS 2 + Isaac ROS + cuVSLAM + nvblox + Nav2)
4. Installs `jetson-av-mission.service`

Each step pre/post-verified. See `docs/AV_STACK.md` for what's in step 3.

## Manual verification on a flashed device

```bash
# 1. Headers found?
ls /usr/local/include/opencv4/opencv2/core.hpp

# 2. Library installed and linked?
ldconfig -p | grep libopencv_core
pkg-config --modversion opencv4

# 3. Python import + CUDA?
/opt/av-env/bin/python -c "
import cv2
print('OpenCV version:', cv2.__version__)
print('CUDA devices  :', cv2.cuda.getCudaEnabledDeviceCount())
build = cv2.getBuildInformation()
for line in build.split('\n'):
    if 'CUDA' in line or 'cuDNN' in line or 'GStreamer' in line:
        print(line)
"

# 4. End-to-end DNN on GPU
/opt/av-env/bin/python <<'EOF'
import cv2, numpy as np
net = cv2.dnn.readNet("/path/to/yolo.onnx")
net.setPreferableBackend(cv2.dnn.DNN_BACKEND_CUDA)
net.setPreferableTarget(cv2.dnn.DNN_TARGET_CUDA_FP16)
img = np.zeros((640, 640, 3), dtype=np.uint8)
blob = cv2.dnn.blobFromImage(img, 1/255.0, (640, 640), swapRB=True, crop=False)
net.setInput(blob)
_ = net.forward()
print("OK: DNN_CUDA forward succeeded")
EOF

# 5. OpenGL / EGL
glxinfo | grep -E 'OpenGL renderer|OpenGL version'
eglinfo | grep -E 'EGL vendor|EGL version'
```

## Troubleshooting

### `cv2.cuda.getCudaEnabledDeviceCount() == 0` after `import cv2`

Either OpenCV was rebuilt without `-D WITH_CUDA=ON` or the device's
CUDA runtime is incompatible. Confirm:

```bash
/opt/av-env/bin/python -c "import cv2; print(cv2.getBuildInformation())" \
  | grep -A2 'CUDA'
```

If it shows `CUDA: NO`, re-run `build_opencv_cuda.sh`.

### `ImportError: libcudnn.so.8: cannot open shared object file`

cuDNN is missing. `apt install libcudnn8` (the L4T-shipped version that
matches CUDA 12.6).

### `glxinfo` reports `llvmpipe` (Mesa) instead of NVIDIA

`nvidia-l4t-3d-core` is missing. Reinstall it via JetPack:

```bash
sudo apt install --reinstall nvidia-l4t-3d-core
```

### `nvcc` not found

The CUDA toolkit isn't installed. JetPack 6.2 includes it under
`/usr/local/cuda-12.6/`; ensure `/etc/profile.d/cuda.sh` adds it to
PATH or source it manually:

```bash
export PATH=/usr/local/cuda-12.6/bin:$PATH
export LD_LIBRARY_PATH=/usr/local/cuda-12.6/lib64:$LD_LIBRARY_PATH
```

### Build runs out of disk

Default `WORK_DIR=/var/tmp/opencv-build` consumes ~3 GB. Check
`df -h /var` before invoking. Override with `WORK_DIR=/path/elsewhere`
(needs ~3 GB free).

### Build runs out of RAM

OpenCV with CUDA contrib modules needs ~6 GB at peak. Lower parallelism:

```bash
JOBS=2 sudo bash /home/j/phase5/build_opencv_cuda.sh
```

### GStreamer pipelines using `nvarguscamerasrc` fail to negotiate

ZED X uses `nvarguscamerasrc` (NVMM buffers) which needs the camera
overlay loaded. Verify:

```bash
v4l2-ctl --list-devices                  # ZED X must appear
gst-launch-1.0 nvarguscamerasrc num-buffers=1 ! fakesink
```

If empty, the DTBO didn't apply. See `docs/DRIVERS.md` §1.3.

## Future work / known gaps

- **OpenCL on Tegra** — not yet enabled. Some apps prefer OpenCL over
  CUDA for portability. Add `-D WITH_OPENCL=ON` and the Mali OpenCL libs
  if you need it.
- **VPI sample suite** — VPI ships with samples that are great smoke
  tests but require manual run today. Add to `verify_opengl_cuda.sh` if
  you want them automated.
- **DeepStream 7.x** — currently not installed by Phase 5. If you need
  multi-stream pipeline composition, install it manually:
  `sudo apt install deepstream-7.0`.
- **TensorRT model compilation** — models go in `/opt/jetson-av/models/`;
  pre-compile to `.engine` files at bake time for fastest cold-start.
  Currently a manual step.
