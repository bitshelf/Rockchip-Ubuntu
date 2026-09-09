# GStreamer 与 gst-rkmpp

Ubuntu 26 的 GStreamer 框架、基础插件和 H.264 parser 来自发行版软件源，随 Ubuntu
安全更新升级。Rockchip SDK 只补充 `gstreamer1.0-rockchip1`，提供
`mpph264enc`、`mppvideodec` 等 MPP 硬件元素；不混用旧 SDK 的整套 GStreamer DEB。

## 准备本地插件

在 SDK 根目录可找到 `Package: gstreamer1.0-rockchip1` 的 DEB 后运行：

```bash
./scripts/prepare-local-debs.sh gstreamer1.0-rockchip1
./scripts/stage-sdk-assets.sh
```

准备脚本按 Debian `Package` 元数据查找输入，不依赖 SDK 中的目录名。构建 Overlay
rootfs 时，通用本地包安装器安装并 hold gst-rkmpp；GStreamer 发行版包仍由 APT 管理。

## 硬件流水线 QA

目标板烧录并启动后运行：

```bash
sudo /usr/libexec/ubuntu-gstreamer-rkmpp-qa
```

测试生成 100 帧 640x360 NV12，按以下单条 pipeline 完成 MPP H.264 编码、parser 和
MPP 解码，并要求正常到达 EOS：

```text
videotestsrc -> mpph264enc -> h264parse -> mppvideodec -> fakesink
```

只有命令成功、日志无协商/硬件错误且出现 EOS 时才输出：

```text
GSTREAMER_RKMPP_OK frames=100 encoder=mpph264enc decoder=mppvideodec
```

该检查依赖真实 `/dev/mpp_service`，不能用 `gst-inspect` 成功代替硬件流水线验收。
