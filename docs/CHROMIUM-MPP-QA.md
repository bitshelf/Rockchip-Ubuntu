# Chromium MPP/V4L2 验收

Desktop 使用仓库构建的 ARM64 Chromium DEB。`use_v4l2_codec=true` 启用
V4L2 解码路径；`docs/patches/chromium/series` 将设备操作接到 libv4l2，
由 libv4l-rkmpp 将 `/dev/video-dec0` 的 stateful V4L2 请求转换为 Rockchip MPP。
构建核对源码版本，记录官方源码归档 SHA256、补丁和 GN 参数校验值。
编译、安装成功均不能代替硬件解码证明。
Linux ARM 的 GPU broker 只增加指定的 RKMPP/DMA heap 设备与 libv4l 插件
资源，以及 DRM render node 和 PanVK ICD；测试保留 GPU 沙箱，也不使用
`--no-sandbox`。默认包装器启用 Linux V4L2 加速功能开关。

普通用户在 GNOME Wayland 会话运行：

```sh
CHROMIUM_MPP_VIDEO=/home/ubuntu/real-footage.mp4 \
  /usr/libexec/ubuntu-chromium-mpp-qa
```

没有显示器时显式设置 `CHROMIUM_QA_HEADLESS=1`，执行同样的真实视频播放和
解码检查。此结果仅证明无显示器模式的硬件解码，不能代表 GNOME 显示验收。

输入必须是真实 H.264 MP4，至少 10 秒、640×360。例如从
[Blender 官方《Tears of Steel》下载目录](https://download.blender.org/demo/movies/ToS/)
取得影片，再无重编码地封装为 MP4。测试保存原片 SHA256，要求：

- 实际播放至少 60 帧，播放时间推进至少 2 秒；
- `chrome://media-internals` 报告 `V4L2VideoDecoder` 且为平台解码器；
- Chromium 进程树持有 `/dev/video-dec0` 或 `/dev/mpp_service`；
- 本次播放期间 `rkvdec` 中断计数增加。
- `SystemInfo.getInfo` 确认 GPU 沙箱启用、GPU 进程崩溃计数为零。

证据保存到 `~/.local/share/ubuntu-hardware-qa/`，包括播放 JSON、真实视频截图、
media-internals 文本/截图、进程设备描述符和浏览器日志。
`FFmpegVideoDecoder`、软件回退或只有设备节点均不能通过。
