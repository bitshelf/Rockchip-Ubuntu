# JR3576 Chromium 155 hardware backends

Apply `series` to the official Chromium 155.0.8059.39 source archive through
`scripts/build-local-debs.sh chromium`. The archive and patch checksums are
included in the package's build-info.

1. Route V4L2 open/ioctl/mmap/close through libv4l2 so libv4l-rkmpp can provide
   the stateful decoder endpoint.
2. Permit the ARM GPU sandbox broker to access the specific MPP, DMA heap,
   render-node and plugin resources needed by the hardware backends.
3. Query decoder configurations through V4L2VideoDecoder's device abstraction.
   Chromium 155's direct V4L2 configuration probe otherwise bypasses libv4l2,
   rejects H.264 as unsupported and never starts the hardware decoder.
4. Add the default-disabled `WebGPUVulkanReadback` feature. A hardware Vulkan
   adapter can use Chromium's existing Skia readback/upload bridge when the
   driver lacks GL/Vulkan external-image interoperability. Vulkan still
   executes WebGPU rendering and compute; presentation includes a CPU copy.
5. Permit the specific ARM Mesa/GLVND modules and DRM metadata needed by early
   GPU sandbox startup. Non-self worker scheduling requests remain denied,
   returning `EPERM` so Mesa can continue without changing worker priority.

The real-footage test requires V4L2VideoDecoder in media-internals, platform
decoding, advancing playback, open MPP resources and increasing rkvdec IRQs.
The GPU sandbox remains enabled. See `docs/CHROMIUM-MPP-QA.md` and
`docs/qa/jr3576-chromium-hardware-20261013.json` for the actual board evidence.

The launcher starts the GPU sandbox before Mesa creates helper threads.
Both decoder and WebGPU QA require `sandboxed=true` and no GPU process crashes.

The launcher also supports a product-selected OpenGLES WebGPU compatibility
backend. Its hardware render/compute evidence does not establish Vulkan or
WebGPU core support; see `docs/WEBGPU-VULKAN-QA.md`.

SDK Chromium 114/120/126 的功能对应关系及未移植项见
[SDK-PATCH-MAPPING.md](SDK-PATCH-MAPPING.md)。
