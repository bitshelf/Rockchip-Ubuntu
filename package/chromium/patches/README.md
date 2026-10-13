# Rockchip Chromium 155 hardware backends

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

6. Initialize Ozone display connections before the early GPU sandbox and
   eagerly open X11's Xlib display. This preserves X11 authentication while
   keeping the GPU sandbox active before Mesa starts helper threads.

The real-footage test requires V4L2VideoDecoder in media-internals, platform
decoding, advancing playback, open MPP resources and increasing rkvdec IRQs.
The GPU sandbox remains enabled. See `docs/CHROMIUM-MPP-QA.md` for the procedure; keep board evidence in the
ignored build output directory.

The launcher starts the GPU sandbox before Mesa creates helper threads.
Both decoder and WebGPU QA require `sandboxed=true` and no GPU process crashes.

The launcher also supports a product-selected OpenGLES WebGPU compatibility
backend. Its hardware render/compute evidence does not establish Vulkan or
WebGPU core support; see `docs/WEBGPU-VULKAN-QA.md`.

SDK Chromium 114/120/126 的功能对应关系及未移植项见
[SDK-PATCH-MAPPING.md](SDK-PATCH-MAPPING.md)。

X11 explicitly uses ANGLE `gles-egl` over Mesa EGL for the compatibility backend;
plain `gles` can select GLX and omit the DMA-BUF import required by NV12 decoding.
Wayland
retains its GL backend. Both paths retain early GPU sandbox startup and must
pass the real-video and WebGPU hardware checks.

X11 的早期 GPU 沙箱同时预加载 GLVND/GLX 库，并保留具体库路径的只读 broker 权限。
ARM GPU 策略允许 Mesa 的只读 `F_DUPFD_QUERY`，其他 `fcntl` 命令继续使用原有限制。

`0007` 允许 ANGLE GLES 的现有 GL 纹理用于 WebGPU 共享图像，并让视频解码
工作线程复用 EGL 初始化时选定的 X11 visual，避免沙箱内重新连接 Xserver。

`0008` 从运行时 libgbm 解析每平面 DMA-BUF 导出接口，保留旧库的原有回退。
旧构建 sysroot 没有该符号时，避免可执行文件的版本脚本将弱引用局部化，
也避免在 KMS 显示节点上直接导出属于独立渲染设备的 GEM handle。

`0009` 为 ANGLE 原生 EGL 后端复用 X11 EGL 子窗口及配置选择，
避免将 GLX 首选 visual ID 当成 EGL 必须提供的 visual，保留 GLX 后端行为。

`0010` 仅对新分配的共享图像检查 GBM 分配能力；导入解码器已有的
NV12 DMA-BUF 时保留句柄和 GL/Vulkan 导入校验，不要求显示设备也能分配同格式。

`0011` 让 Mesa GBM 对已有视频缓冲执行真实导入校验，即使其格式不能用于
显示设备的 scanout 分配；保留 minigbm 原有限制与全部平面、偏移及句柄校验。
