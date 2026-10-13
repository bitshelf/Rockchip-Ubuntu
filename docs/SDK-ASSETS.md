# SDK 板级输入暂存、发布与下载

内核 Image、最终 kernel config、基础 DTB、DT overlay、选定的内核模块和本地
DEB 是 SDK 构建产物，不提交到 Ubuntu Git 仓库。`scripts/stage-sdk-assets.sh` 将这些文件放入
Ubuntu 的 platform-asset 接口，并生成 SHA256 清单。它可以直接供 ARM64 native
构建使用，也可以封装后发布到 Forgejo/GitHub Release，CI 不依赖 SDK 工作树。

## 在 SDK 主机暂存

先完成 SDK 的 kernel、DTB、overlay、kernel-modules 和需要携带的本地 DEB
构建。当前清单要求 `output/linux-headers/` 中存在唯一匹配的 ARM64 内核头文件
包。Ubuntu 仓库位于 SDK 根目录下时，脚本默认读取其父目录的 `output/`：

```bash
cd /path/to/ubuntu
./scripts/stage-sdk-assets.sh
./scripts/stage-sdk-assets.sh --check
```

SDK 位于其他位置时，在未跟踪的 `.env` 中设置：

```bash
SDK_DIR="/path/to/rockchip-sdk"
SOC_MODEL="rk3576"
```

x86 主机默认暂存到 `build/platform-assets/<soc>/`，ARM64 主机默认使用
`/var/lib/ubuntu-ci/build/platform-assets/<soc>/`。可以通过
`PLATFORM_ASSET_DIR` 覆盖本地路径。bundle 保留 SDK 生成的 DTB/DTBO 文件名，
模块版本从 `output/kernel-modules/lib/modules/` 动态发现，不在脚本中绑定版本。
需要携带的 KO 由 `config/kernel-modules/modules.conf` 的 `MODULE_ENTRIES`
显式选择；它是 Ubuntu 产品功能清单，不与 SoC 绑定，SDK 中其他模块不会进入
bundle。需要使用不同清单时通过 `KERNEL_MODULE_CONFIG` 指定。
重新暂存时可以将旧的完整模块 bundle 原子迁移为只包含选定 KO 的新格式。

最终 SDK `kernel/.config` 会进入 `boot/kernel.config`，并在暂存和 CI 验收时与
`config/kernel/overlay-root.conf` 比较。EROFS、ext4、OverlayFS 和 initrd 所需
能力必须为 built-in，不能只检查 defconfig 片段。`modules.builtin` 与
`modules.builtin.modinfo` 也随 bundle 携带，供 initramfs-tools 识别内建模块；
它们不是额外驱动集。

暂存和 CI 检查还会读取每个 KO 的 ARM64 ELF `.modinfo`，要求 vermagic
与 `kernel-release` 一致，并验证 headers DEB 中的
`usr/src/linux-headers-<release>/include/config/kernel.release`。只改文件名、
目录名或包的 Architecture 不能替代这些检查。内核重新配置后须重新生成模块
和 SDK `linux-headers:aarch64` 包；使用同一次构建的最终配置和 Module.symvers。
外部 DTB 的 `/chosen/bootargs` 也须与 bootfs policy 一致，特别是 root 文件系统
模式和 RT CPU 隔离参数；二进制输入与板级参数仍由 `artifacts/` 提供。

本地 DEB 由 `config/local-debs/packages.conf` 的 `DEB_ENTRIES` 选择。每项格式
是“SDK `output/` 相对文件匹配式｜预期架构｜用途”。目录部分不能使用通配符，
文件名可以匹配版本变化，但必须恰好找到一个包。暂存脚本读取 DEB control
metadata，拒绝 amd64/armhf 包进入 ARM64 bundle，并记录包名、版本、架构和用途。
需要使用其他清单时通过 `LOCAL_DEB_CONFIG` 指定。

仓库需要自行构建的本地包统一使用 `scripts/build-local-debs.sh <key>`，构建条目在
`config/local-debs/build.conf` 中声明；已有 SDK vendor DEB 和外部 data 文件统一
使用 `scripts/prepare-local-debs.sh` 汇集。rootfs 通过
`scripts/install-local-debs.sh` 一次性安装配置选中的包。新增软件包通常只需增加
构建 recipe 与三份清单条目，不再创建成组的 package-specific 顶层脚本。

每个 bundle 包含：

- `boot/Image`、`boot/kernel.config`、SDK 输出的 DTB/DTBO 和可选
  `extlinux.conf`；
- `modules/lib/modules/<kernel-release>/` 下由配置选中的 KO；
- 同一版本目录下的 `modules.builtin` 和 `modules.builtin.modinfo`；
- `debs/` 下由配置选中的本地 Debian 包；
- `kernel-release`、`module-manifest.tsv`、`local-deb-manifest.tsv`、
  `asset-info` 和 `SHA256SUMS`。

本步骤只建立可校验、可同步的二进制输入，不代表 DEB 已安装进 rootfs。具体
安装动作应由使用该包的功能提交负责，并核对 manifest 中的包名和版本。

## 生成发布包

打包脚本先完整执行 `stage-sdk-assets.sh --check`，随后生成所有者和时间戳固定的
tar.zst 以及配套 SHA256：

```bash
./scripts/pack-platform-assets.sh \
  "$PWD/artifacts/platform-assets-${SOC_MODEL}.tar.zst"
```

Release tag 必须是不可变版本。发布脚本发现同名资产时直接失败，不覆盖旧包：

```bash
ASSET_PROVIDER=github \
ASSET_REPOSITORY=owner/repository \
ASSET_TAG=platform-assets-<version> \
ASSET_TOKEN="<release-token>" \
PLATFORM_ASSET_BUNDLE="$PWD/artifacts/platform-assets-${SOC_MODEL}.tar.zst" \
./scripts/publish-platform-assets.sh
```

Forgejo 还需设置 `ASSET_SERVER_URL`。两种 provider 都使用对应 Release API；
token 只由 CI secret 或当前 shell 提供，不写入 `.env`、日志或 bundle。

## ARM64 native 与 CI 下载

ARM64 手工构建可以继续直接使用
`/var/lib/ubuntu-ci/build/platform-assets/<soc>/`。也可以和 GitHub/Forgejo CI 一样
从 Release 下载：

```bash
SOC_MODEL="<soc>" \
PLATFORM_ASSET_BUNDLE_URL="https://server/owner/repo/releases/download/<tag>/platform-assets-<soc>.tar.zst" \
./scripts/fetch-platform-assets.sh
```

公开 Release 自动下载同 URL 的 `.sha256`；也可显式提供
`PLATFORM_ASSET_BUNDLE_SHA256`。私有仓库通过 secret 设置完整的
`PLATFORM_ASSET_AUTH_HEADER`。下载脚本先验证压缩包 SHA256、成员路径和内部
`SHA256SUMS`，然后原子替换 `platform-assets/<soc>/`。

## CI 使用

摄像头 IQ 数据通过 `CAMERA_IQ_DIR` 指定的绝对目录输入。stage 脚本将其中
JSON 复制到 bundle 的 `iqfiles/` 并纳入 `SHA256SUMS`；OverlayFS 构建在安装
相机运行包后将它们装入 `/etc/iqfiles/`。文件名须与 sensor/module/lens
匹配，例如 `ov13855_default_default.json`。不指定时不额外安装校准数据。
IQ 数据不放进源码仓库；借用其他模组的数据只能证明采帧链路，不能作为该
模组图像质量已校准的依据。

MYD-LR3576 CAM3 的 OV13855 overlay 保存在
`config/dts/optional/myd-lr3576/rk3576-ov13855-cam3.dtso`。它引用 LR3576
专有的 Jaguar 节点，不能自动应用到 JR3576 的 `myd-jr3576.dtb`。
需要该摄像头配置时，把它复制到所选 `DTS_OVERLAY_DIR`，并在 disable-dsi
overlay 之后应用，以重新启用摄像头使用的共享 PHY。

Forgejo 和 GitHub workflow 在 rootfs 构建前执行下载或已有资产检查：

```bash
./scripts/fetch-platform-assets.sh
./scripts/stage-sdk-assets.sh --check
```

Forgejo native runner 未配置 URL 时可用 `--if-configured` 复用共享输出目录；
GitHub CI 要求配置发布 URL。二进制仍不进入 Git。详细变量和两套 workflow 见
[CI-ASSETS.md](CI-ASSETS.md)。
