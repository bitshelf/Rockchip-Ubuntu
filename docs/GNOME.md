# GNOME 桌面移植

顺序为 Server → GNOME → XFCE。GNOME 使用 Ubuntu 的 GDM、
Ubuntu session 和 Mutter/Wayland；基础 rootfs 继承 Server 的包策略、有线 DHCP seed 和
无预置账户配置。软件源版本由实际 manifest 记录，不在脚本中写死 GNOME 版本。

```bash
./build.sh desktop --check
./build.sh desktop
ROOTFS_TARBALL=/var/lib/ubuntu-ci/build/images/ubuntu-26.04-desktop-arm64.rootfs.tar.gz \
  FIRSTBOOT_PROFILE=desktop ./build.sh overlay-root
```

rootfs 在原生 ARM64 主机构建，bootfs/内核/U-Boot/recovery 继续使用本机 x86
工作流。组装前需设置并验证 PLATFORM_ASSET_DIR，输出指定到独立的 GNOME
镜像路径，不能覆盖正在验收的 Server 产物。刷写前检查 EROFS 大小不超过实际
rootfs 分区；不沿用历史分区偏移。

`config/ubuntu-image/desktop.packages` 在 Server seed 上添加 GNOME、图形验收工具、
输入法和蓝牙组件；具体安装版本以本次 manifest 为准。
PipeWire/WirePlumber 使用发行版默认包；板级 UCM2、WirePlumber 路由和真实
音频播放录音属于下一项功能，不在本项中安装现有音频草稿。

Desktop 定义同时预置 Chromium 和其 content snap。`ubuntu-image` 要求显式列出
每个 snap 的 base；2026-09-28 的稳定版 Chromium 使用 `core24`，`cups`
使用 `core26`。升级稳定渠道后应检查实际 snap 元数据和构建日志中的依赖校验，
不能只复用旧的 revision 清单。

首次启动沿用 firstboot 建号入口，不添加默认账户、密码或自动登录。
Server 不运行 GNOME 安装步骤；GNOME 镜像持久启用 GDM 和 graphical.target。
Desktop 的 firstboot 服务使用 `Type=exec`，串口建号提示运行时 GDM greeter
仍可在 HDMI 显示。完成建号后才可登录用户会话；Server 保留原先的串口阻塞顺序。
板级组装将继承的 networkd seed 改为 NetworkManager，并停用 networkd，
使桌面网络设置和实际管理器一致；使用全新 userdata 验证首次 DHCP。

GNOME 镜像默认禁用空闲自动息屏：`org.gnome.desktop.session idle-delay=0`。
配置随镜像编译到 GSettings schemas，适用于新用户，无需板级参数。
已有用户若自行保存过该设置，可用 `gsettings reset org.gnome.desktop.session idle-delay`
恢复镜像默认值。验收同时检查已连接的显示输出处于启用状态，避免仅凭会话进程判定桌面显示正常。

## Mali-G52 图形栈验证

默认板级组装使用 SDK 的 `libmali`。该包提供 EGL/GLES，但当前打包版本未
导出 Vulkan ICD；仅安装 `mesa-vulkan-drivers` 时，`vulkaninfo` 可能只枚举
`llvmpipe`。验证 Mesa Panfrost 时，在独立内核输出中应用
`config/kernel/panfrost-nonrt.config`，使用同一 `myd-jr3576.dts` 构建 DTB，
并以 `GPU_STACK=panfrost` 组装 Desktop。该选项跳过 `libmali`，保留 Mesa
EGL/GLES/Vulkan 和 DMA heap 权限。不得混用启用内建 `mali_kbase` 的内核与
Panfrost 用户空间。Mali-G52 的 PanVK 在 [Mesa 官方支持表](https://docs.mesa3d.org/drivers/panfrost.html)中仍属于实验性
Vulkan 路径；必须以板端 `vulkaninfo`、GNOME 会话和 WebGPU 实测结果验收。

## 验收

- 源码：`bash tests/host/test-gnome.sh`，覆盖变体选择、包边界和 GDM 离线启用。
- 构建：保存 rootfs SHA256、manifest、build-info、qa.json；构建成功不等于板端通过。
- 登录界面：root 执行 `tests/target/test-gnome.sh greeter`。
- 登录后：root 执行 `tests/target/test-gnome.sh session`，要求真实连接的显示器、
  active local Wayland 用户会话、GNOME 的 Mali 驱动映射和 GPU 设备描述符。
- 以上只证明会话与硬件渲染路径存在；显示正确性、交互、重启恢复，以及 GPU、
  RKNPU、RKMPP、RGA 等完整功能测试仍需独立保存证据。不能把 greeter 当作用户会话。
- HDMI/DP/codec 映射、真实播放和录音后续逐路验收；没有接线或现场确认时记录待测。

Ubuntu 官方包信息：[GNOME Shell](https://packages.ubuntu.com/source/resolute/gnome-shell)、
[GDM ARM64](https://packages.ubuntu.com/resolute/arm64/gdm3)。
