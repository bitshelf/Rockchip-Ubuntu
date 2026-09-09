# libmali 与 Server headless EGL

libmali 是 SDK 外部二进制输入，不进入 Git。仓库只记录所选包的用途、安装策略、
设备权限和 QA。`config/local-debs/packages.conf` 的 `gpu-runtime` 条目要求
`SDK_OUTPUT_DIR/libmali/` 中恰好有一个 ARM64 libmali DEB；
`scripts/stage-sdk-assets.sh` 将包的来源、Package、Version、Architecture 和校验值
写入 platform assets。

准备输入示例：

```bash
install -d "${SDK_OUTPUT_DIR}/libmali"
install -m 0644 /path/to/libmali_*_arm64.deb "${SDK_OUTPUT_DIR}/libmali/"
./scripts/stage-sdk-assets.sh
```

`scripts/build-overlay-root.sh` 从 manifest 的 `gpu-runtime` 用途解析包，安装并 hold，
运行 `ldconfig`，且要求 `libEGL.so.1` 最终解析到
`/usr/lib/aarch64-linux-gnu/mali/`。dma-buf heap 的 udev 规则同时供 Server 服务和
后续 Desktop 非 root 会话使用。Server 不引入 X/Wayland session、Mesa 测试工具或
桌面负载；但必须从 Ubuntu archive 安装该 vendor ELF 在 control 中声明的 libdrm、
Wayland 和 X11/XCB ABI 库，否则 `dpkg` 会拒绝配置，不能用 `--force-depends` 绕过。

## QA

主机最小检查：

```bash
./tests/host/test-libmali.sh
```

烧录后，把两个 target QA 文件放在同一目录，以 root 执行：

```bash
./tests/target/test-gpu-headless-egl.sh
```

通过条件不是“包存在”。测试必须打开一个 DRM card，创建 GBM device 和 EGL ES2
pbuffer/context，使用 `glClear` 产生红色帧并通过 `glReadPixels` 读回，同时 EGL/GL
vendor 或 renderer 必须标识 ARM/Mali。最终 JSON 包含
`"marker": "GPU_HEADLESS_EGL_OK"`、实际 DRM 节点、vendor/renderer、RGBA 和
libmali 版本，作为本次镜像的机器可读验收证据。

首次通过后还要由 Linux init system 完成真实重启并重复测试：

```bash
adb shell 'sync; systemctl reboot'
# 等待同一物理 ADB 设备恢复，并确认 /proc/sys/kernel/random/boot_id 已变化
./tests/target/test-gpu-headless-egl.sh
```

Ubuntu 的 `adbd` 不保证 Android 协议的 `adb reboot` 会调用 systemd；只看到 ADB
连接关闭不等于发生了重启，必须以 boot ID 变化为准。
