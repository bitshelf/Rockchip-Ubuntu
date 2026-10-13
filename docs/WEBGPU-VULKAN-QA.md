# WebGPU/Vulkan 硬件验收

Desktop 的 Panfrost 内核与 Mesa 提供 Mali-G52 EGL/GLES 硬件渲染；
PanVK 的 Vulkan 能力需要单独核对，不能由 EGL/GLES 结果推定。
Chromium 的 WebGPU 读回缓冲区需要映射进 V8 沙箱地址空间。使用
`config/kernel/ubuntu-common.config` 的 `CONFIG_ARM64_VA_BITS_48=y`；
39 位内核只能提供有限地址空间，V8 的部分预留模式可能出现间歇共享
ArrayBuffer 映射失败。验收须保留沙箱，并重复验证渲染、读回和计算，
不能把单次重试成功作为稳定性通过。
RK3576 平台选择 `config/kernel/panfrost-nonrt.config`、`GPU_STACK=panfrost`，并把
`config/dts/optional/rk3576-panfrost.dtso` 加入本产品的 overlay 集合。
该 overlay 使用 300 MHz、750 mV 的单一保守 OPP：Panfrost 尚未接入
厂商 PVTM 分档与 SRAM read-margin 调整，不能直接使用带
`opp-supported-hw` 的厂商频点表。GPU 功能验收不代表动态调频或最高性能
验收；恢复厂商高频 OPP 前须完成对应电源及分档适配。
还须应用 `docs/patches/kernel/0002-panfrost-rk3576-allow-disabling-runtime-pm.patch`。
上述 overlay 显式禁止 GPU runtime autosuspend，以避免厂商 genpd 在
Panfrost 关闭文件后重新上电时出现 idle ACK 超时。这个配置增加空闲耗电，
runtime PM 与系统休眠不在本次功能验收范围内。
还须应用 `docs/patches/kernel/0004-panfrost-enable-mmu-interrupts-at-probe.patch`：
MMU 中断在初始化时开启，避免首个 tiler heap 缺页要等 GPU timeout/reset
后才恢复。该修复回移自上游同名补丁，不能通过允许 GPU timeout 日志代替。
此 overlay 将厂商 DTB 的 IRQ 名称 `GPU/MMU/JOB` 改为驱动要求的
`gpu/mmu/job`，将时钟别名改为 `core/bus`；不要用于厂商 Mali 内核产品。
安装 Vulkan ICD 后，以普通用户在 GNOME Wayland 会话执行：

```sh
WEBGPU_REAL=1 /usr/libexec/ubuntu-webgpu-vulkan-qa
```

没有显示器时设置 `CHROMIUM_QA_HEADLESS=1`，测试在 Chromium headless 模式执行。
该模式的成功不代表物理显示器或 GNOME 会话通过。
PanVK 如要求实验开关，需显式设置
`PAN_I_WANT_A_BROKEN_VULKAN_DRIVER=1`，并在验收记录中注明。

测试创建 WebGPU adapter/device，绘制三角形，将纹理复制到 MAP_READ buffer，
统计回读像素。通过条件同时要求渲染/回读完成、有红色像素、adapter 为 ARM/Mali，
且不是 fallback；浏览器 SystemInfo 也必须报告 ARM/Mali GPU。
SwiftShader、lavapipe 或只有 `navigator.gpu` API 均不能通过。

测试保存 `render.json`、`gpu-info.json`、`chrome-gpu.txt`、截图、ICD 清单及
浏览器日志到 `~/.local/share/ubuntu-hardware-qa/`。板端通过证据应另存入具体
批次报告；本文说明验收方法，不声明硬件测试已经成功。

## OpenGLES compatibility 硬件路径

Chromium 155 同时编译 Dawn OpenGLES backend。在显式选择该策略的 Panfrost 镜像中，
GNOME 安装步骤生成 `/etc/chromium/rockchip-webgpu-backend`（`gles-compat`）。
Chromium 启动器选择 ANGLE GLES 与 Dawn OpenGLES，并设置 compatibility
模式；显式 `--use-webgpu-adapter=` 参数可以覆盖此产品策略。
这是实际 GPU backend，不修改 Vulkan 版本或 WebGPU feature/limit 声明。
该产品默认策略提供 compatibility 功能级别；应用需遵守对应能力限制。

```sh
WEBGPU_REAL=1 WEBGPU_BACKEND=gles-compat /usr/libexec/ubuntu-webgpu-vulkan-qa
```

验收页显式请求 `featureLevel: "compatibility"`，要求 adapter 非 fallback、
Dawn adapter 的描述与 Chromium GPU 设备信息均指向 Mali，再绘制三角形并
回读像素，以及校验 compute shader 的 256 个输出值。测试启用 Chromium
developer features 以取得实际 driver description；未改动 GPU 沙箱。
结果记录 `coreFeaturesAndLimits=false`，成功标记为
`WEBGPU_GLES_COMPAT_HARDWARE_OK`，与 Vulkan 成功标记分别保存。
运行记录保存在 Git 忽略的输出目录。最终镜像、重启和并发 soak 分别验收。

## 新版 PanVK 的原生 Vulkan 实测

RK3576 的硬件 Vulkan 能力与 Ubuntu 当前驱动暴露的 API 必须分别判断。
旧 Mesa 26.0.8 报告 1.0.335，并不表示 Mali-G52 硬件不支持 Vulkan 1.1。
实验验证使用官方 Mesa 开发快照
`76b9372c4e5d186f57d22d3a4f95dd1c5e04ece2`（26.3.0-devel），源码归档 SHA256
为 `2f8463e9b9d3565ab4661b78cbdf7d6539944ef6b89c1880ec302579a85faaee`。
稳定版 Mesa 26.2.4 的归档文档仍列 G52 Vulkan 1.0，不能混用开发版能力表。

该开发快照需要 `package/mesa/patches/0001-panvk-skip-non-mali-render-nodes.patch`：
板上的 RKNPU 同样提供 render 节点，未匹配 Mali 的节点应返回
`VK_ERROR_INCOMPATIBLE_DRIVER`，使枚举继续，而不是报内存不足并整体中止。
补丁不改变 API 版本、功能或硬件限制。实机使用实验开关和单一 Panfrost ICD，
成功枚举 Mali-G52 r1 MC3（vendor 0x13b5）、Vulkan 1.3.363；`vkcube --wsi
wayland --c 120` 返回 0，Panfrost job IRQ 从 9097 增至 9897。

这只证明原生 Vulkan 设备初始化及 120 帧绘制/呈现。该驱动仍是实验实现，
`conformanceVersion=0.0.0.0`，不能据此宣称通过 Khronos 一致性测试。
Chromium ANGLE/Vulkan 当前因 GLES 3.0 初始化失败而未通过；GL/Vulkan
互操作路径也缺少所需扩展。

## Vulkan WebGPU core 与读回呈现

`0004-opt-in-vulkan-webgpu-readback-bridge.patch` 添加默认关闭的
`WebGPUVulkanReadback`。WebGPU 使用实际硬件 Vulkan adapter，网页 Canvas
通过 Chromium 现有的 Skia 读回/上传桥接呈现，包含 CPU 纹理复制。
ANGLE 与 GNOME 的图形前端仍使用 GLES。补丁保留真实 API、feature 与 limit
校验，不修改驱动声明。

`0005-linux-arm-mesa-resources-for-early-gpu-sandbox.patch` 配合
`--gpu-sandbox-start-early`，提供明确的 Mesa/GLVND 库与 DRM 元数据访问权限。
Mesa 对其他线程的调度请求返回 `EPERM`，继续使用原优先级；不授权修改
其他进程或线程。MPP 与 WebGPU 测试均要求 GPU 沙箱启用且没有 GPU 进程崩溃。

安装独立的 `mesa-panvk-experimental` DEB 后，在普通桌面用户会话执行：

```sh
PAN_I_WANT_A_BROKEN_VULKAN_DRIVER=1 \
VK_DRIVER_FILES=/usr/share/vulkan/icd.d/panfrost_icd.aarch64.json \
WEBGPU_REAL=1 WEBGPU_BACKEND=vulkan-readback \
  /usr/libexec/ubuntu-webgpu-vulkan-qa
```

该路径已取得 Mali-G52 的实机 core 渲染、256 项计算结果读回和网页 Canvas
呈现记录，GPU 沙箱启用、崩溃计数为零。独立驱动包保留 Ubuntu Mesa 文件，
移除该包即可撤销实验驱动。原生驱动构建与打包见
[package/mesa/README.md](../package/mesa/README.md)。
最终镜像仍须完成对应候选镜像的目标、重启和 soak 门禁；机器证据保存在
Git 忽略的输出目录。此功能验证不代表 Khronos 一致性认证或性能验收。
