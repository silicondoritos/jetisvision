---
title: DMABUF Zero-Copy
layout: default
description: "ZED X → Tegra ISP → CMA → Axelera Metis NPU: kernel dma_buf bridge, GStreamer pipeline, ftrace setup, and pass/fail verification script."
nav_order: 16
---

# DMABUF Zero-Copy: ZED X → ISP → CMA → Metis

From the moment a frame leaves the ZED X imager to the moment Metis returns an inference result, **no CPU memcpy** of the pixel buffer occurs. The frame lives in a CMA-backed `dma_buf`, is consumed by Metis via PCIe DMA into BAR2, and the result tensor is written back into a separately-allocated `dma_buf` that the application maps once.

## Architecture

```
                   +------------------+
ZED X imager ─CSI/GMSL─► MAX9296A    │  (ZED Link Mono deserializer)
                   +────────┬─────────+
                            ▼
                   +──────────────────+
                   │  Tegra VI / ISP  │  CSI host driver, 5.15-tegra
                   +────────┬─────────+
                            ▼
                   +──────────────────+
                   │  NvBufSurface    │  exporter: nvmap / tegra-buf
                   │  (CMA-backed)    │  dma_buf inode N
                   +────────┬─────────+
                            │  fd
               ┌────────────┼────────────┐
               ▼                        ▼
    +──────────────────+     +───────────────────────+
    │ libargus consumer│     │ /dev/axl-metis (axl)  │
    │  (zedx capture)  │     │  ioctl AXL_IMPORT_FD  │
    +──────────────────+     +───────────┬───────────+
                                         ▼
                             dma_buf_attach(dev=axl_pci)
                             dma_buf_map_attachment(BIDIRECTIONAL)
                             sg_table → IOVA via Tegra SMMU
                                         ▼
                             +───────────────────────+
                             │  Metis BAR2 PCIe DMA  │
                             │  inference engine     │
                             +───────────┬───────────+
                                         ▼
                             result dma_buf inode M
                                         ▼
                             AV stack (mmap once or import to GST)
```

Key invariants:

- The pixel buffer's `dma_buf` inode (call it **N**) appears in the attachment list of **two** devices: the camera/ISP device and the `axl` PCI device. Attach count ≥ 2.
- No `memcpy` is observable in any user process between the frame arriving from the ISP and the inference being submitted. Verified via `perf record -e cycles -g -p <pid>` — there must be no `__memcpy_generic` / `memcpy_aarch64` frames in the hot path on the producer or consumer process.
- The `axl` driver maps the buffer with `DMA_BIDIRECTIONAL` and uses the Tegra IOMMU group (already attached by `arm-smmu` per the dmesg traces from the L4T tree).
- The result tensor is also a `dma_buf` (allocated from the same CMA heap), so the consumer doesn't see a CPU copy on the back side either.

## Kernel CONFIG dependencies

Already enabled in the PREEMPT_RT defconfig per [Kernel Options]({{ '/KERNEL_OPTIMIZATIONS' | relative_url }}) and confirmed in the Verification Report §3:

```
CONFIG_DMA_SHARED_BUFFER=y
CONFIG_DMABUF_HEAPS=y
CONFIG_DMABUF_HEAPS_CMA=y
CONFIG_DMABUF_HEAPS_SYSTEM=y
CONFIG_DMABUF_SYSFS_STATS=y
CONFIG_SYNC_FILE=y
CONFIG_CMA=y
CONFIG_CMA_SIZE_MBYTES=512
CONFIG_DMA_CMA=y
CONFIG_IOMMU_DMA=y
CONFIG_ARM_SMMU=y
```

Sanity check after first boot:

```bash
zgrep -E 'DMABUF_HEAPS|DMABUF_SYSFS|CMA|ARM_SMMU' /proc/config.gz
ls /dev/dma_heap/                       # must contain "linux,cma" and "system"
ls /sys/kernel/dmabuf/buffers/          # populated once first export happens
```

If `/sys/kernel/dmabuf/buffers/` doesn't exist post-flash, `CONFIG_DMABUF_SYSFS_STATS=y` did not take. Re-verify the defconfig fragment in `scripts/01_extract_and_patch.sh`.

## Buffer allocation paths — which heap when

| Producer | Heap | Rationale |
|---|---|---|
| ZED X capture (libargus / nvarguscamerasrc) | `linux,cma` (NvBufSurface backing) | NVMM expects physically contiguous; ISP descriptors require it. |
| Metis result tensor | `linux,cma` | PCIe DMA wants physical contiguity unless SMMU scatter-gather is used. |
| Telemetry / blackbox / metadata | `system` | Scatter-gather fine; no DMA constraint. |

## ZED X → NvBufSurface → `dma_buf` FD

L4T's standard pattern. The ZED X kernel driver presents the camera as a v4l2 / Argus device. Capture path:

```c
/* After CaptureSession::createOutputStream and IFrameConsumer::acquireFrame: */
Argus::IFrame *iFrame = Argus::interface_cast<Argus::IFrame>(frame);
Argus::Image *image = iFrame->getImage();
NV::IImageNativeBuffer *iNative =
    Argus::interface_cast<NV::IImageNativeBuffer>(image);

/* Hand back a NvBufSurface FD instead of CPU-mapping the image. */
int dmabuf_fd = iNative->createNvBuffer(
    Argus::Size2D<uint32_t>(width, height),
    NVBUF_COLOR_FORMAT_NV12_ER,         /* matches Metis input expectation */
    NVBUF_LAYOUT_PITCH,
    /*createFlag*/ 0
);
/* dmabuf_fd is a real Linux dma_buf FD.
   Verify: readlink /proc/self/fd/<fd> → "/dmabuf:[NNNNN]" */

/* Pass to Metis: */
struct axl_import_fd req = {
    .fd      = dmabuf_fd,
    .width   = width,
    .height  = height,
    .pixfmt  = AXL_PIXFMT_NV12,
    .flags   = AXL_IMPORT_BIDIRECTIONAL,
};
ioctl(metis_dev_fd, AXL_IOCTL_IMPORT_FD, &req);
```

Notes:

- `NvBufSurface` exporter is `nvmap` on R36.x; `/sys/kernel/dmabuf/buffers/<inode>/exporter_name` will read `nvmap` for ISP-produced buffers.
- Pixel format must be NV12 — the ISP already produces it, so no GPU/VIC colorspace conversion step is needed.
- Don't use `madvise(MADV_DONTNEED)` on the mapping — the ISP descriptor table holds the page references for the lifetime of the `CaptureSession`.

## In-tree `axl` driver — `dma_buf` import path

This is the bridge that converts a `dma_buf` FD from the producer side into a Metis-addressable IOVA. Lives in `drivers/misc/axelera/axl_dmabuf.c` alongside the existing `axl_main.c` / `axl_pci.c` / `axl_ioctl.c`.

```c
/* drivers/misc/axelera/axl_dmabuf.c */
#include <linux/dma-buf.h>
#include <linux/dma-mapping.h>
#include <linux/scatterlist.h>
#include <linux/iommu.h>
#include "axl.h"

struct axl_imported_buf {
    struct list_head            node;
    u32                         handle;
    struct dma_buf             *dmabuf;
    struct dma_buf_attachment  *attach;
    struct sg_table            *sgt;
    enum dma_data_direction     dir;
    size_t                      size;
    dma_addr_t                  iova_base;
    bool                        contiguous;
};

int axl_import_dmabuf(struct axl_device *axl,
                      struct axl_import_fd __user *uargs)
{
    struct axl_import_fd args;
    struct axl_imported_buf *ibuf;
    struct dma_buf *dmabuf;
    enum dma_data_direction dir;
    int ret;

    if (copy_from_user(&args, uargs, sizeof(args)))
        return -EFAULT;

    dmabuf = dma_buf_get(args.fd);
    if (IS_ERR(dmabuf))
        return PTR_ERR(dmabuf);

    ibuf = kzalloc(sizeof(*ibuf), GFP_KERNEL);
    if (!ibuf) { ret = -ENOMEM; goto err_put; }

    ibuf->dmabuf = dmabuf;
    ibuf->size   = dmabuf->size;
    dir = (args.flags & AXL_IMPORT_BIDIRECTIONAL) ? DMA_BIDIRECTIONAL :
          (args.flags & AXL_IMPORT_TO_DEVICE)     ? DMA_TO_DEVICE     :
                                                    DMA_FROM_DEVICE;
    ibuf->dir = dir;

    ibuf->attach = dma_buf_attach(dmabuf, &axl->pdev->dev);
    if (IS_ERR(ibuf->attach)) { ret = PTR_ERR(ibuf->attach); goto err_free; }

    ibuf->sgt = dma_buf_map_attachment(ibuf->attach, dir);
    if (IS_ERR(ibuf->sgt)) { ret = PTR_ERR(ibuf->sgt); goto err_detach; }

    if (ibuf->sgt->nents == 1) {
        ibuf->iova_base  = sg_dma_address(ibuf->sgt->sgl);
        ibuf->contiguous = true;
    } else {
        ibuf->contiguous = axl_iova_is_contiguous(ibuf->sgt);
        ibuf->iova_base  = sg_dma_address(ibuf->sgt->sgl);
    }

    ibuf->handle = axl_alloc_handle(axl);
    mutex_lock(&axl->ibuf_lock);
    list_add(&ibuf->node, &axl->imported_bufs);
    mutex_unlock(&axl->ibuf_lock);

    args.handle    = ibuf->handle;
    args.iova_base = ibuf->iova_base;
    args.size      = ibuf->size;
    if (copy_to_user(uargs, &args, sizeof(args))) { ret = -EFAULT; goto err_unmap; }

    trace_axl_dmabuf_import(ibuf->handle, dmabuf, ibuf->iova_base, ibuf->size);
    return 0;

err_unmap:  dma_buf_unmap_attachment(ibuf->attach, ibuf->sgt, dir);
err_detach: dma_buf_detach(dmabuf, ibuf->attach);
err_free:   kfree(ibuf);
err_put:    dma_buf_put(dmabuf);
    return ret;
}

int axl_release_dmabuf(struct axl_device *axl, u32 handle)
{
    struct axl_imported_buf *ibuf = axl_find_ibuf(axl, handle);
    if (!ibuf) return -ENOENT;

    trace_axl_dmabuf_release(handle, ibuf->dmabuf);
    list_del(&ibuf->node);
    dma_buf_unmap_attachment(ibuf->attach, ibuf->sgt, ibuf->dir);
    dma_buf_detach(ibuf->dmabuf, ibuf->attach);
    dma_buf_put(ibuf->dmabuf);
    kfree(ibuf);
    return 0;
}
```

Tracepoint definitions in `drivers/misc/axelera/axl_trace.h`:

```c
TRACE_EVENT(axl_dmabuf_import,
    TP_PROTO(u32 handle, struct dma_buf *dmabuf, dma_addr_t iova, size_t size),
    TP_ARGS(handle, dmabuf, iova, size),
    TP_STRUCT__entry(
        __field(u32,         handle)
        __field(unsigned long, inode)
        __field(u64,         iova)
        __field(size_t,      size)
        __string(exporter,   dmabuf->exp_name)
    ),
    TP_fast_assign(
        __entry->handle = handle;
        __entry->inode  = file_inode(dmabuf->file)->i_ino;
        __entry->iova   = iova;
        __entry->size   = size;
        __assign_str(exporter, dmabuf->exp_name);
    ),
    TP_printk("handle=%u inode=%lu exporter=%s iova=0x%llx size=%zu",
              __entry->handle, __entry->inode, __get_str(exporter),
              __entry->iova, __entry->size)
);
```

Once compiled in, surfaces at `/sys/kernel/debug/tracing/events/axl/axl_dmabuf_import/` and `/sys/kernel/debug/tracing/events/axl/axl_dmabuf_release/`.

## Userspace handoff

```c
/* userspace/axl_zerocopy.c */
int axl_zerocopy_submit(int axl_fd, int dmabuf_fd,
                        const struct axl_shape *shape,
                        struct axl_inference_result *out)
{
    struct axl_import_fd imp = {
        .fd     = dmabuf_fd,
        .width  = shape->w,
        .height = shape->h,
        .pixfmt = shape->pixfmt,
        .flags  = AXL_IMPORT_TO_DEVICE,
    };
    if (ioctl(axl_fd, AXL_IOCTL_IMPORT_FD, &imp) < 0)
        return -errno;

    int result_fd = axl_alloc_result_dmabuf(axl_fd, shape->result_size);
    struct axl_submit req = {
        .input_handle  = imp.handle,
        .result_fd     = result_fd,
        .model_id      = shape->model_id,
        .timeout_us    = 50000,
    };
    if (ioctl(axl_fd, AXL_IOCTL_SUBMIT, &req) < 0)
        return -errno;

    struct pollfd pfd = { .fd = req.fence_fd, .events = POLLIN };
    if (poll(&pfd, 1, shape->timeout_ms) <= 0)
        return -ETIMEDOUT;

    out->result_fd  = result_fd;
    out->fence_fd   = req.fence_fd;
    out->latency_us = req.completion_us - req.submit_us;

    ioctl(axl_fd, AXL_IOCTL_RELEASE_IMPORT, &imp.handle);
    return 0;
}
```

The `dma_fence_fd` path means we never busy-wait — the kernel signals the fence from the Metis IRQ handler, and `poll()` is woken.

## GStreamer pipeline

For the AV-stack path that pipes through GStreamer for ROS 2 image_transport interop:

```bash
gst-launch-1.0 -v \
    nvarguscamerasrc sensor-id=0 ! \
    'video/x-raw(memory:NVMM),width=1920,height=1080,format=NV12,framerate=60/1' ! \
    nvvidconv ! \
    'video/x-raw(memory:NVMM),format=NV12' ! \
    axinferencenet model=/opt/axelera/models/yolov8n-coco.json device=metis-0:01:0 \
                   import-mode=dmabuf  output-buffer-mode=dmabuf ! \
    fakesink sync=false
```

Critical caps constraint: `(memory:NVMM)` must appear on every link. The moment a link drops to plain `video/x-raw`, GStreamer inserts a CPU copy via `nvvidconv` and zero-copy is broken. Verify the property name for your Voyager version: `gst-inspect-1.0 axinferencenet | grep -i dma`.

For ROS 2 publishing without breaking zero-copy, use `isaac_ros_argus_camera` rather than the generic `image_publisher`.

## Kernel tracepoints + ftrace setup

Run `scripts/setup_dmabuf_trace.sh` before the workload, then `scripts/stop_dmabuf_trace.sh <output_file>` after. The setup script enables:

- `dma_fence:{init,emit,signaled,wait_start,wait_end,destroy}`
- `axl:{axl_dmabuf_import,axl_dmabuf_release}`
- `function_graph` filtered to `dma_buf_{attach,detach,map_attachment,unmap_attachment,export,fd}`

## Verification

Run `scripts/verify_dmabuf_zerocopy.sh` — it starts the GStreamer pipeline, captures ftrace, runs `perf record`, inspects `/sys/kernel/dmabuf/buffers/`, and checks four invariants:

| Invariant | Check |
|---|---|
| I1 | At least one dma_buf inode shows `attachments` ≥ 2 during the run |
| I2 | That inode's `exporter_name` is one of `{nvmap, system, tegra-buf}` |
| I3 | `axl:axl_dmabuf_import` fires N times where N == frames submitted |
| I4 | No `memcpy/__memcpy_generic` frame in perf hot path > 1% self |

Pass example (`result.json`):

```json
{
  "I1_attach_count_ge2": true,
  "I2_known_exporter":   true,
  "I3_axl_imports":      true,
  "I4_no_memcpy_hot":    true,
  "detail": {
    "imports":             300,
    "releases":            300,
    "fence_wait_lines":    600,
    "multi_attach_inodes": ["41023", "41024", "41025", "41026"],
    "exporters":           ["nvmap"],
    "memcpy_hot":          []
  },
  "pass": true
}
```

Trace excerpt:

```
gst-launch-1.0-3142 [003] d..2. 123.456789: axl_dmabuf_import: handle=17 inode=41023 exporter=nvmap iova=0x80100000 size=3110400
gst-launch-1.0-3142 [003] d..2. 123.456891: dma_fence_init: driver=axl timeline=metis-0 ctx=2 seqno=17
gst-launch-1.0-3142 [003] d..2. 123.473102: dma_fence_emit: driver=axl timeline=metis-0 ctx=2 seqno=17
gst-launch-1.0-3142 [001] dN.2. 123.473115: dma_fence_wait_start: driver=axl timeline=metis-0 ctx=2 seqno=17
   <kworker/u16:2-89> [005] d..2. 123.481903: dma_fence_signaled: driver=axl timeline=metis-0 ctx=2 seqno=17
gst-launch-1.0-3142 [001] dN.2. 123.481940: dma_fence_wait_end: driver=axl timeline=metis-0 ctx=2 seqno=17
gst-launch-1.0-3142 [003] d..2. 123.481955: axl_dmabuf_release: handle=17 inode=41023
```

~8 ms fence wait for a single yolov8n inference at 1080p NV12 on Metis. `mmap_count == 0` on the frame buffer is the smoking gun for "no userspace CPU mapping."

<!-- HW-CAPTURE: paste real result.json, trace excerpt, and sysfs dump after first capture run -->

## Failure modes

| Symptom | Diagnosis | Fix |
|---|---|---|
| `axinferencenet` errors `unknown property import-mode` | Voyager 1.6's GStreamer plugin uses a different prop name | `gst-inspect-1.0 axinferencenet \| grep -i dma`; update pipeline |
| `attachments` always == 1 | Voyager runtime is CPU-mapping via mmap | Check `lsof` for `/dmabuf:` entries with `mem` access; switch to libargus path |
| `memcpy_aarch64` > 5% in perf | `nvvidconv` is converting format/colorspace | Make sink and source caps bit-identical including format, color_range, framerate, width, height |
| `dma_fence_wait_*` shows > 50 ms | Metis back-pressured or PCIe link degraded | `lspci -vvv -d 1f9d:1100 \| grep LnkSta` — must show `Speed 8GT/s, Width x4` |
| `exporter_name` is `system` not `nvmap` | Argus allocating from system heap | Pass `nvbuf-memory-type=4` (CMA) on `nvarguscamerasrc` |
| `axl_dmabuf_import` never fires | Driver path not wired or ioctl number mismatch | `dmesg \| grep axl`; `strace -e ioctl gst-launch ...`; verify `AXL_IOCTL_IMPORT_FD` magic agrees between kernel and userspace include |
