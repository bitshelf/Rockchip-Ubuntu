# ARM64 Linux 镜像构建

面向 Rockchip ARM64 平台的独立镜像构建与硬件适配工具，支持 Server、GNOME 和 XFCE。
在本地编译 SDK 二进制，由 ARM64 主机构建 rootfs，再使用 SDK 工具合成可烧录镜像。

当前软件包基线来自配置的 Ubuntu 软件源；具体版本由构建配置和产物 manifest 记录。
本项目不代表 Canonical 官方发行、认证或支持。
来源归属、商标与商业再分发要求见 [商业使用说明](docs/COMMERCIAL-USE.md)。

## 产品矩阵

| 变体 | 桌面 | 架构 |
| --- | --- | --- |
| `server` | 无 | arm64 |
| `desktop` | GNOME | arm64 |
| `desktop-xfce` | XFCE | arm64 |

## 快速开始

先按 [构建主机指南](docs/ARM64-BUILD-HOST.md)准备依赖，并配置匹配的 SDK 输入：

```bash
cp .env.example .env       # 按本机和平台输入修改；不要提交 .env
./build.sh server --check  # 检查配置和依赖
./build.sh server          # 构建 Server 基础 rootfs
```

完整文件系统合成与可烧录镜像打包见 [构建与交付流程](docs/BUILD-WORKFLOW.md)。
镜像默认通过首次启动创建管理员账号，不预置账号和密码，详见
[首次启动配置](docs/UBUNTU-FIRSTBOOT.md)。

## 文档导航

| 内容 | 文档 |
| --- | --- |
| 主机准备、构建流程与 SDK 打包 | [构建主机](docs/ARM64-BUILD-HOST.md) · [构建与交付](docs/BUILD-WORKFLOW.md) |
| CI 构建与镜像发布 | [CI 与 Release](docs/CI-ASSETS.md) |
| GPU、视频、摄像头、NPU、音频等功能 | [硬件功能与验收](docs/HARDWARE-FEATURES.md) |
| 商业使用、许可与社区协作 | [商业使用说明](docs/COMMERCIAL-USE.md) · [贡献指南](CONTRIBUTING.md) |
