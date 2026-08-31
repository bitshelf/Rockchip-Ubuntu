# SDK 板级输入暂存与同步

内核 Image、基础 DTB、DT overlay 和选定的内核模块是 SDK 构建产物，不提交到
Ubuntu Git 仓库。`scripts/stage-sdk-assets.sh` 将这些文件放入 Ubuntu 的
platform-asset 接口，并生成 SHA256 清单；ARM64 手工构建和 Forgejo Runner
从同一个 `BUILD_OUTPUT_DIR` 读取它们。

## 在 SDK 主机暂存

先完成 SDK 的 kernel、DTB、overlay 和 kernel-modules 构建。本仓库位于
SDK 根目录下时，脚本默认读取其父目录的 `output/`：

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

每个 bundle 包含：

- `boot/Image`、SDK 输出的 DTB/DTBO 和可选 `extlinux.conf`；
- `modules/lib/modules/<kernel-release>/` 下由配置选中的 KO；
- `kernel-release`、`module-manifest.tsv`、`asset-info` 和 `SHA256SUMS`。

## 同步到 ARM64 构建主机

暂存脚本不绑定构建主机、登录用户或传输协议。使用部署环境现有的同步工具，
把整个 platform-asset 目录复制到 ARM64 主机对应目录。例如使用 rsync 时：

```bash
ASSET_SOURCE="/path/to/local/platform-assets/<soc>"
ASSET_DESTINATION="<build-host>:<remote-platform-asset-directory>"
rsync -a "${ASSET_SOURCE}/" "${ASSET_DESTINATION}/"
```

目标目录是构建主机 `BUILD_OUTPUT_DIR` 下的
`platform-assets/<soc>/`。它不依赖登录用户的 home 或 `/userdata`；
`ubuntu-ci` Runner 必须对目标目录具有读取和执行权限。

同步完成后，在目标目录执行 `sha256sum -c SHA256SUMS`。同步命令只传输该
platform-asset bundle，不同步 Ubuntu 源码目录或其他构建产物。

## CI 使用

Forgejo workflow 在 rootfs 构建前执行：

```bash
./scripts/stage-sdk-assets.sh --check
```

因此 Runner 使用的 `BUILD_OUTPUT_DIR` 必须与同步目标一致。CI 不从 Git 下载
这些二进制，也不会把它们加入仓库；缺失、版本目录不一致或 SHA256 改变都会在
构建开始前失败。
