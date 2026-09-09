# 构建与交付流程

[返回项目首页](../README.md) · 硬件功能与验收

本页集中说明构建主机分工、SDK 输入、文件系统合成和镜像打包入口。
首次搭建先阅读 [ARM64 主机准备](ARM64-BUILD-HOST.md)，上传与 CI 操作见
二进制输入上传指南。

## 构建拓扑

本仓库的主要开发目录位于 ARM64 构建主机。手动修改代码后，可以
在 ARM64 主机完成 rootfs 构建和最小 QA，再提交到 Forgejo。

1. x86 主机编译内核模块、DT overlay 和其他依赖 SDK 的板级二进制；
2. 将二进制及其校验信息同步到 ARM64 主机上的本项目开发目录；
3. ARM64 主机原生构建目标 rootfs；x86 QEMU 兼容路径见下文交叉构建说明；
4. 将 rootfs 构建结果同步回 x86 主机，使用仅支持 x86 的 Rockchip 工具合成
   可烧录镜像。

目标 rootfs 在非容器化 Debian/Ubuntu 主机上构建，原生 ARM64 为首选。
ARM64 手动构建和 CI 应通过 `BUILD_OUTPUT_DIR` 共用约定的产出目录；x86 默认使用
仓库内的 `build/`。主机和服务准备见 [ARM64-BUILD-HOST.md](ARM64-BUILD-HOST.md)。

## Server rootfs

```bash
cp .env.example .env       # 按构建主机修改；不要提交 .env
./build.sh server --check  # 只检查配置和本机依赖
./build.sh server          # 构建 rootfs
```

ARM64 主机默认写入 `/var/lib/ubuntu-ci/build`，x86 主机默认写入仓库内的
`build/`。两者都可用 `.env` 的 `BUILD_OUTPUT_DIR` 覆盖。详细说明和产物定义见
[Server 构建指南](ubuntu-build.md)。

## SDK 板级输入

内核 Image、DTB、DT overlay 和 modules 不进入 Git。先在 SDK 主机暂存并生成
SHA256 清单，再同步到 ARM64 手工构建和 Forgejo CI 共用的构建输出目录：

```bash
./scripts/stage-sdk-assets.sh
```

目录布局、同步和验收方法见 [SDK-ASSETS.md](SDK-ASSETS.md)。

## 独立 bootfs

已同步 platform-assets 后，可在 x86、ARM64 或 Forgejo host runner 上生成相同的
ext4 bootfs。生成与验收均不需要挂载镜像：

```bash
./build.sh bootfs
./build.sh bootfs --check
```

产物布局、板级策略和离线验收项见 [BOOTFS.md](BOOTFS.md)。

## EROFS lower 与 userdata OverlayFS

Server rootfs 和 platform-assets 都通过验收后，生成不可变 lower、userdata
seed 以及带 OverlayFS initramfs 的 bootfs：

```bash
./build.sh overlay-root
./build.sh overlay-root --check
```

内核配置、分区契约、掉电恢复策略和目标板 QA 见
[EROFS-OVERLAY-ROOT.md](EROFS-OVERLAY-ROOT.md)。

## x86 交叉编译 ARM64

在 x86_64 主机使用 GNU AArch64 交叉工具链。宿主机可以是 Debian 或 Ubuntu，
目标 Ubuntu 基础版本由
`.env` 的 `CROSS_BASE_TAG` 选择，不固化在脚本中。

```bash
CROSS_BASE_TAG="<ubuntu-base-tag>" ./scripts/cross-build-env.sh --prepare
CROSS_BASE_TAG="<ubuntu-base-tag>" ./scripts/cross-build-env.sh --check
```

完整配置、使用方式和版本迁移步骤见
[CROSS-COMPILE.md](CROSS-COMPILE.md)。

## U-Boot extlinux/FDTOVERLAYS

Rockchip U-Boot 2017.09 的 extlinux 启动接入、FDT overlay 回移、RKIMG 回退和
版本移植说明见
[UBOOT-EXTLINUX-FDTOVERLAYS.md](UBOOT-EXTLINUX-FDTOVERLAYS.md)。该功能
只交付一个合并补丁，应用前必须对目标 U-Boot 执行 `git apply --check`。
