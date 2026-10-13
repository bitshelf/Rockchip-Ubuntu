# SDK Chromium 补丁到 Chromium 155 的迁移

SDK 的 `debian/packages-patches/chromium/` 有 114、120、126 三套补丁，
不能按旧文件名直接叠加到 155。当前 `series` 包含三个重新适配的补丁，
其中解码器、libv4l 插件和事件处理延续 SDK 的设计，并非没有使用 SDK 适配。
版本升级时，以下映射也必须随源码和实测更新。

| SDK 功能与补丁编号 | Chromium 155 处理 | 验收范围 |
|---|---|---|
| Linux V4L2 decoder：114/0001、0014；120、126/0001 | GN `use_v4l2_codec=true` 和 Linux V4L2 decoder 路径；launcher 启用解码特性。新增 `0003` 将 supported-config 查询改经 V4L2Device，防止绕过插件 | H.264 真实视频、media-internals/V4L2VideoDecoder、MPP 设备与 IRQ 证据；见 CHROMIUM-MPP-QA |
| libv4l decoder/plugin/mmap：114/0001、0003；120、126/0003、0004 | `0001` 动态加载 libv4l2，通过包装后的 open/ioctl/mmap/munmap/close 操作设备，不照搬旧 generated stubs | 需要配套 libv4l-rkmpp DEB |
| eventfd/POLLIN：114/0006；120、126/0007 | `0001` 同时接受 POLLPRI 与 POLLIN，保留真实 V4L2 设备事件语义 | 源变化和解码队列事件 |
| DRI/X11 依赖：114/0013、0018；120、126/0013、0014 | 不照搬仅 X11 的依赖裁剪。`0002` 为 ARM GPU broker 明确允许 MPP、DMA heap、render node、插件和 Vulkan 资源 | Wayland + GPU sandbox + 硬件后端；不得用关闭 sandbox 代替 |
| V4L2 encoder：114/0002；120、126/0002 | 未移植为本次 decoder 功能 | 浏览器硬件编码未验收 |
| libv4l capture：114/0004；120、126/0005 | 未移植到浏览器摄像头链路 | ISP/3A 服务验收不能替代 WebRTC/capture 验收 |
| 优先首个摄像头：114/0007；120、126/0008 | 不强制更改用户设备选择 | 多摄像头策略另行适配 |
| 缺少 capture formats：114/0012；120、126/0012 | 未添加全局宽松接受策略 | 摄像头采集尚无浏览器证据 |
| cld3 未对齐访问：114/0005；120、126/0006 | 未直接套旧修改；本次不宣称消除所有 ARM 对齐风险 | 需有当前源码故障与复现再迁移 |
| 非 Ozone 编译：114/0008；120、126/0009 | 当前 GN 明确启用 Wayland、X11、headless Ozone，不适用旧非 Ozone 配置 | ARM64 cross-build 通过 |
| 旧内核 UAPI：114/0009、0016；120、126/0001 中的旧头文件保护 | 使用 Chromium 的 ARM64 sysroot，当前编译不需追加旧常量兜底 | 不代表任意旧 sysroot 均受支持 |
| 无输入 fence 新建 fence：114/0010；120、126/0010 | 未强行复制旧 GPU fence 改动 | 新平台需验证 dmabuf 同步与长时视频 |
| Wayland implicit external sync：114/0011；120、126/0011 | 未全局禁用 | 与 compositor/driver 组合有关，不能用旧 HACK 替代同步验收 |
| 强制关闭 modifiers：114/0020；120、126/0015 | 保留当前上游协商策略 | 不将旧 DDK 限制施加给 Mesa/Panfrost |
| Mali DDK X11 EGL config：120、126/0016 | 未全局修改 EGL config 选择 | GNOME/Panfrost 与未来 XFCE/libmali 必须分别验证 |
| 强制 validating decoder：114/0019 | 未全局强制 | 当前浏览器保留自身 decoder 选择 |
| HEVC/AV1 VDA：114/0015、0017 | 未照搬旧 VDA 编解码器补丁，不据 H.264 结果宣称 HEVC/AV1 成功 | 每种格式都需真实视频验收 |

`0002` 还包含现代 Vulkan 资源访问权限，这是当前版本新增的 sandbox
适配，不是 SDK 旧补丁的逐行副本。Vulkan/WebGPU 的成功与否取决于实际 ICD、
ANGLE 和 Dawn 能力；上述补丁及编译成功不等于硬件 Vulkan WebGPU 已通过。
