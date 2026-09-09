# Rockchip MPP 与 100 帧编解码验收

MPP 使用 SDK 提供的 ARM64 `librockchip-mpp1`、`librockchip-vpu0` 和
`rockchip-mpp-demos` DEB。二进制不进入 Git，复制到 SDK 输出接口后重新生成
platform-assets：

```bash
install -d "${SDK_OUTPUT_DIR}/mpp"
install -m 0644 /path/to/librockchip-mpp1_*_arm64.deb "${SDK_OUTPUT_DIR}/mpp/"
install -m 0644 /path/to/librockchip-vpu0_*_arm64.deb "${SDK_OUTPUT_DIR}/mpp/"
install -m 0644 /path/to/rockchip-mpp-demos_*_arm64.deb "${SDK_OUTPUT_DIR}/mpp/"
./scripts/stage-sdk-assets.sh
```

镜像安装并 hold 三个包，同时安装 `/usr/libexec/ubuntu-mpp-qa`。udev 将
`/dev/mpp_service` 设置为 `0666`，允许 Server 服务和 Desktop 会话使用同一硬件
媒体设备。

## 验收标准

```bash
sudo /usr/libexec/ubuntu-mpp-qa
```

测试由 MPP 生成 100 帧 640x360 H.264，要求 encoder 日志中的唯一帧号完整覆盖
`0..99`，随后把同一 bitstream 硬件解码成 100 帧 YUV。包存在、设备节点存在或命令
返回零都不能单独判定通过；必须同时得到非空编码流、真实解码字节以及：

```text
RKMPP_ENCODE_OK frames=100 bytes=<non-zero>
RKMPP_DECODE_OK frames=100 bytes=<non-zero>
MPP_SMOKE_OK frames=100 codec=h264 size=640x360
```

临时 bitstream 和 YUV 写入 `/run`，测试结束后删除，避免占用 OverlayFS upper。
首次通过后重启目标板并重复执行，确认不是安装过程留下的临时状态。
