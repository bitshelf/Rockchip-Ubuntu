# RGA 运行库与 dma-buf 验收

RGA 使用 SDK 提供的 ARM64 `librga2` 和 `librga-dev` DEB 作为外部输入。二进制包
不进入 Git，放入 `SDK_OUTPUT_DIR/rga/` 后由 platform asset manifest 记录包名、
版本、架构和 SHA256：

```bash
install -d "${SDK_OUTPUT_DIR}/rga"
install -m 0644 /path/to/librga2_*_arm64.deb "${SDK_OUTPUT_DIR}/rga/"
install -m 0644 /path/to/librga-dev_*_arm64.deb "${SDK_OUTPUT_DIR}/rga/"
./scripts/stage-sdk-assets.sh
```

镜像只安装并 hold `librga2`。`librga-dev` 仅用于构建
`/usr/libexec/ubuntu-rga-smoke`，不会进入目标 rootfs。

## 验收

主机检查：

```bash
./tests/host/test-rga.sh
```

烧录后将 target QA 脚本放到设备执行：

```bash
sudo ./tests/target/test-rga.sh
```

通过条件不是设备节点或包存在。smoke 从 dma-heap 分配并映射 dma-buf，CPU 写入
sentinel 后结束 WRITE 同步，RGA 导入同一个 fd 并执行 128x128 RGBA color fill，
随后 CPU 在成对的 READ 同步区间内读回整帧。只有 RGA 调用成功、像素不再是
sentinel、整帧像素一致且同步调用全部成功时，才输出：

```text
RGA_SMOKE_OK
```

首次通过后由 systemd 真实重启，确认 boot ID 变化并重复同一用例。
