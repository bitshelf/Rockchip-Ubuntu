# Rockchip Ubuntu 构建

默认启用首次启动建号，不预置账户和密码。配置与客户量产回滚见
[UBUNTU-FIRSTBOOT.md](docs/UBUNTU-FIRSTBOOT.md)。

## 构建拓扑

Ubuntu 仓库的主要开发目录位于 ARM64 构建主机。手动修改代码后，可以
ARM64 主机完成 rootfs 构建和最小 QA，再提交到 Forgejo。

1. x86 主机编译内核模块、DT overlay 和其他依赖 SDK 的板级二进制；
2. 将二进制及其校验信息同步到 ARM64 主机上的 Ubuntu 开发目录；
3. ARM64 主机原生构建 Ubuntu rootfs，避免 x86 QEMU 构建经常崩溃；
4. 将 rootfs 构建结果同步回 x86 主机，使用仅支持 x86 的 Rockchip 工具合成
   可烧录镜像。

## 产品矩阵

| 变体 | 桌面 | 发行版 | 架构 |
| --- | --- | --- | --- |
| `server` | 无 | Ubuntu | arm64 |
| `desktop` | GNOME | Ubuntu | arm64 |
| `desktop-xfce` | XFCE | Ubuntu | arm64 |

Ubuntu rootfs 在非容器化 Debian/Ubuntu 主机上构建，原生 ARM64 为首选。
在 x86 上，构建产出目录默认是仓库的 `build/`；在 ARM64 上，手动 native 构建
与 Forgejo CI 必须通过 `BUILD_OUTPUT_DIR` 使用同一个构建产出目录。
构建主机和 Forgejo 环境搭建见
[ARM64-BUILD-HOST.md](docs/ARM64-BUILD-HOST.md)。

## Ubuntu Server rootfs


```bash
cp .env.example .env       # 按构建主机修改；不要提交 .env
./build.sh server --check  # 只检查配置和本机依赖
./build.sh server          # 构建 rootfs
```

ARM64 主机默认写入 `/var/lib/ubuntu-ci/build`，x86 主机默认写入仓库内的
`build/`。两者都可用 `.env` 的 `BUILD_OUTPUT_DIR` 覆盖。详细说明和产物定义见
[ubuntu-build.md](docs/ubuntu-build.md)。

## SDK 板级输入

内核 Image、DTB、DT overlay、modules 和 vendor DEB 不进入 Git。先在 SDK 主机
暂存并生成 SHA256 清单，再封装为 Forgejo/GitHub Release 资产；ARM64 native、
Forgejo 和 GitHub CI 使用相同下载/校验接口：

```bash
./scripts/stage-sdk-assets.sh
./scripts/pack-platform-assets.sh "$PWD/artifacts/platform-assets-${SOC_MODEL}.tar.zst"
```

目录布局与发布方法见 [SDK-ASSETS.md](docs/SDK-ASSETS.md)，双 CI 变量见
[CI-ASSETS.md](docs/CI-ASSETS.md)。

## 独立 bootfs

已同步 platform-assets 后，可在 x86、ARM64 或 Forgejo host runner 上生成相同的
ext4 bootfs。生成与验收均不需要挂载镜像：

```bash
./build.sh bootfs
./build.sh bootfs --check
```

产物布局、板级策略和离线验收项见 [BOOTFS.md](docs/BOOTFS.md)。

DTS overlay 的源码编译、bootfs 安装、离线合并以及目标重启验收见
[DTS-OVERLAY.md](docs/DTS-OVERLAY.md)。

## EROFS lower 与 userdata OverlayFS

Server rootfs 和 platform-assets 都通过验收后，生成不可变 lower、userdata
seed 以及带 OverlayFS initramfs 的 bootfs：

```bash
./build.sh overlay-root
./build.sh overlay-root --check
```

内核配置、分区契约、掉电恢复策略和目标板 QA 见
[EROFS-OVERLAY-ROOT.md](docs/EROFS-OVERLAY-ROOT.md)。

ADB 使用 Ubuntu `adbd` 和通用 USB FunctionFS gadget，保持 root shell 与 host
network namespace，使 `adb shell ip -c a` 与串口看到相同接口。移植与双通道 QA
见 [ADB.md](docs/ADB.md)。

## RGA 2D 加速

RGA runtime 随镜像安装，但开发包只用于构建验收工具。目标板 QA 必须完成真实
dma-buf color fill、同步读回并输出 `RGA_SMOKE_OK`，见 [RGA.md](docs/RGA.md)。

## MPP 视频编解码

MPP runtime 和验收工具随镜像安装。目标板必须完成同一 H.264 bitstream 的 100 帧
硬件编码和 100 帧硬件解码，见 [MPP.md](docs/MPP.md)。

## V4L2

patched v4l-utils、libv4l-rkmpp 和独立 V4L2 QA 见
[V4L2.md](docs/V4L2.md)。

## ISP 与 OV13855

镜像移植 RKISP/RKAIQ 服务；OV13855 仅作为可替换的摄像头验收示例。基础配置不
携带板级 IQ，产品定制通过独立提交加入匹配的 overlay、IQ 包和验收条件。真实 30 帧
摄像头 QA 见 [ISP.md](docs/ISP.md)。

## RKNPU2

RKNPU2 运行库、server 和 MobileNet 验收模型由 SDK 外部输入构建成 DEB；目标 QA
要求普通用户完成 Top-1、延迟和 200/200 soak 推理，见
[RKNPU.md](docs/RKNPU.md)。

## GStreamer 与 gst-rkmpp

GStreamer 主体使用 Ubuntu 26 软件源，SDK 仅提供 Rockchip MPP 插件。目标 QA 以
100 帧 NV12 完成硬件编码、H.264 解析和硬件解码，见
[GSTREAMER.md](docs/GSTREAMER.md)。

## ALSA 命令行工具

Server 默认安装 `alsa-utils`；非破坏性的声卡、PCM 和 mixer CLI 验收见
[ALSA-UTILS.md](docs/ALSA-UTILS.md)。

## x86 交叉编译 ARM64

在 x86_64 主机使用 GNU AArch64 交叉工具链。宿主机可以是 Debian 或 Ubuntu，
目标 Ubuntu 基础版本由
`.env` 的 `CROSS_BASE_TAG` 选择，不固化在脚本中。

```bash
CROSS_BASE_TAG="<ubuntu-base-tag>" ./scripts/cross-build-env.sh --prepare
CROSS_BASE_TAG="<ubuntu-base-tag>" ./scripts/cross-build-env.sh --check
```

完整配置、使用方式和版本迁移步骤见
[CROSS-COMPILE.md](docs/CROSS-COMPILE.md)。

## Recovery OTA

`updateEngine` 从 SDK 的干净源码提交构建为 ARM64 DEB，并在 EROFS 合成阶段安装。
update.img 与 OTA image 直接使用 SDK 的 `edit-package-file`、
`edit-ota-package-file`、`updateimg` 和 `ota-updateimg`，不复制 Rockchip 工具、
不维护固定分区 mask。见 [OTA.md](docs/OTA.md)。

## Factory image

仓库基于 Rockchip 原生 `parameter.txt` 保留 vendor boot 分区，根据实际 EROFS
负载计算 rootfs 容量并插入独立 bootfs；最终封装仍由 SDK `updateimg` 完成。见
[FACTORY-IMAGE.md](docs/FACTORY-IMAGE.md)。

## Rockchip 镜像测试

SDK `external/rockchip-test/` 可封装为默认不集成的 `rockchip-test`
deb。Server 与 Desktop 使用独立 QA profile，危险和长时间 vendor 测试不会被自动
执行。构建与目标板用法见 [ROCKCHIP-TEST.md](docs/ROCKCHIP-TEST.md)。

## U-Boot extlinux/FDTOVERLAYS

Rockchip U-Boot 2017.09 的 extlinux 启动接入、FDT overlay 回移、RKIMG 回退和
版本移植说明见
[UBOOT-EXTLINUX-FDTOVERLAYS.md](docs/UBOOT-EXTLINUX-FDTOVERLAYS.md)。该功能
只交付一个合并补丁，应用前必须对目标 U-Boot 执行 `git apply --check`。

Server、GNOME 和 XFCE 的默认登录 shell 为 `/bin/bash`；首启管理员、root
以及通过 `useradd`、`adduser` 新建的普通用户均采用 Bash。
`/bin/sh` 保留 Ubuntu 的系统脚本解释器配置。
