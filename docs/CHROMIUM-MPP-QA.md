# Chromium MPP/V4L2 验收

GNOME 镜像由 `ubuntu-image` 在每次构建时从 Canonical ARM64
`latest/stable` 渠道解析并预置 Chromium，不固定旧版本 DEB。构建同时显式预置该 revision 声明的 base 与 content-provider snap，避免 ubuntu-image 生成依赖不完整的离线镜像。版本号必须在目标板证据中记录；旧 126/132 包不得进入平台资源清单。

目标 GNOME Wayland 会话安装稳定渠道 Chromium、`libv4l-rkmpp1` 和 GStreamer MPP 后执行：

```sh
CHROMIUM_MPP_REAL=1 tests/target/test-chromium-mpp.sh
```

该测试生成并保存真实 H.264 MP4，经 Chromium 循环播放，要求 `rkvdec`
中断计数增加且 Chromium 进程持有 `/dev/video-dec0` 或
`/dev/mpp_service`。测试通过 DevTools 自动采集 `chrome://media-internals`
文本和 PNG 截图，并强制播放条目报告 `V4L2VideoDecoder`。没有 JR3576
Wayland 会话、MPP 节点、真实视频及上述持久证据时不得宣称硬解通过。
