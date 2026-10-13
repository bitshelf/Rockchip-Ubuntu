# 将 kernel、U-Boot、DEB、KO 上传到 GitHub / Forgejo

在本地 SDK 编译 kernel、U-Boot、模块和 DEB，将它们暂存到被 Git 忽略的
`ubuntu/artifacts/`，再上传为外部附件。ARM64 CI 下载这批输入后构建目标
rootfs；GitHub 还使用原 SDK 工具合成可烧录整包。二进制不使用 `git add`、Git LFS
或额外源码分支传输。

上传附件也是对外提供二进制；上传前核对 [商业使用与再分发要求](COMMERCIAL-USE.md)，
尤其是 kernel/U-Boot 源码对应关系及专有运行库的再分发许可。

下文命令均在本仓库根目录执行。SDK 的编译命令随版本不同，以该 SDK 的
`./build.sh help` 为准；这里处理已经编译完成的产物。

## 1. 准备输入目录

```text
ubuntu/artifacts/
├── build.json
├── platform-assets/<soc>/
│   ├── boot/                       # Image、kernel.config、基础 DTB、logo 等
│   ├── modules/lib/modules/<release>/  # 选中的 KO 和内建模块元数据
│   ├── debs/                       # arm64 或允许的 all DEB
│   ├── kernel-release
│   ├── module-manifest.tsv
│   ├── local-deb-manifest.tsv
│   └── SHA256SUMS                  # 由暂存脚本生成
├── sources/
│   ├── update-engine.tar
│   └── update-engine.tar.source-info
├── firmware/                       # 生成整包镜像所需的 SDK 打包输入
│   ├── MiniLoaderAll.bin
│   ├── uboot.img
│   ├── parameter.txt
│   ├── package-file
│   ├── afptool
│   ├── rkImageMaker
│   ├── manifest.json
│   └── ...                         # package-file 选择的 misc/recovery 等
└── manifests/                      # 可选：显式选择的软件包版本清单
```

不要直接把所有 KO 平铺到 `artifacts/`，也不要只复制 DEB 而漏掉清单。
`config/kernel-modules/modules.conf` 选择需要的模块；
`config/local-debs/packages.conf` 选择 SDK 输出中的 DEB；
`config/local-debs/install.conf` 决定各产品实际安装哪些 DEB。
新增软件包需要同步维护相应选择和安装配置。详见 [SDK-ASSETS.md](SDK-ASSETS.md)。

例如 SDK 就在本仓库的上级目录：

```bash
export SDK_DIR="$(cd .. && pwd)"
export SDK_OUTPUT_DIR="$SDK_DIR/output"
export SOC_MODEL=rk3588
# 指向本次内核实际构建目录的最终 .config；使用 O= 时通常不在源码目录。
export SDK_KERNEL_CONFIG="/absolute/path/to/kernel-build/.config"
export PLATFORM_ASSET_DIR="$PWD/artifacts/platform-assets/$SOC_MODEL"

./scripts/stage-sdk-assets.sh
./scripts/stage-sdk-assets.sh --check
UPDATE_ENGINE_SOURCE_ARCHIVE="$PWD/artifacts/sources/update-engine.tar" \
  ./scripts/stage-update-engine-source.sh
```

`SOC_MODEL` 是本地采集输入的选择，不是需要在 CI 页面填写的参数。改为 RK3576
时使用 `rk3576` 并提供匹配的实际文件。Image、KO、headers DEB 和最终配置必须来自
同一次内核构建；检查会验证模块 vermagic、ARM64 架构和 headers 的 kernel.release。

在 `artifacts/build.json` 写入平台选择，例如：

```json
{
  "schema": "ubuntu-build-inputs-v1",
  "soc": "rk3588",
  "variants": ["server", "desktop", "desktop-xfce"],
  "gpu_stack": "panfrost",
  "chromium_webgpu_backend": "auto",
  "boot": {
    "base_dtb": "board.dtb",
    "cmdline": "root=PARTLABEL=rootfs rootfstype=erofs rootwait ro"
  }
}
```

将 `board.dtb` 替换为 `platform-assets/<soc>/boot/` 中的实际文件名；GPU 配置必须
与内核和用户态驱动匹配。示例不表示 RK3588 已通过硬件验收。
当前两套 workflow 都构建上述三个产品，`variants` 应包含三者。
默认安装当前软件源可选的最新版本；只有显式配置 `package_manifests` 才冻结版本，
详见 PACKAGE-MANIFEST.md。

## 2. 加入 U-Boot 和整包打包输入

先在 SDK 按原有流程成功生成一次 `update.img`，确认 `output/firmware/` 和
`output/update/Image/package-file` 对应本次选择的平台，再回到本仓库执行：

```bash
python3 scripts/pack-firmware.py stage --sdk "$SDK_DIR"
python3 scripts/pack-firmware.py check
python3 scripts/build-inputs.py check
```

`stage` 将 SDK 选中的 U-Boot、loader、分区表、recovery 等及原始 x86 打包工具
复制到 `artifacts/firmware/`，并生成覆盖这些文件的 SHA256 manifest。
CI 自行生成 boot/rootfs/userdata，无需将旧的三个文件系统镜像作为输入上传。
只有构建 rootfs 时，`firmware/` 可以省略；GitHub 的完整镜像 workflow 必须提供它。

若 `artifacts/firmware/` 已存在，脚本会拒绝覆盖。更新 U-Boot 等文件时，先将旧目录
移到 `artifacts/` 之外备份，再重新执行 `stage`。不要替换文件后继续使用旧 manifest。
整套固件输入必须匹配目标硬件，不能只因 SoC 名称相同就复用其他板子的 loader/分区表。

## 3. 推送源码

```bash
git status --short
git check-ignore artifacts/build.json artifacts/platform-assets/"$SOC_MODEL"/boot/Image
git push origin ubuntu26
# Forgejo remote 地址按自己的仓库设置。
git push forgejo ubuntu26
```

只提交脚本、配置、文档和 patch。不要强制添加被忽略的 `artifacts/`。
两端需要先有 `.github/workflows/server.yaml` / `.forgejo/workflows/server.yaml`。

## 4. 命令行上传到 Forgejo

目标服务先配置可用的 `native-arm64` runner；runner 是原生 ARM64 主机，具有该项目
要求的构建工具和非交互 sudo 权限。公开输入包可以不配置下载 secret。

在当前 shell 导出 Forgejo token。可以用交互读取避免进入 shell 历史：

```bash
read -rsp 'Forgejo token: ' ASSET_TOKEN; echo
export ASSET_TOKEN
python3 scripts/publish-build-inputs.py forgejo \
  --server http://192.168.1.209:3000 \
  --repository ubuntu/ubuntu --build --ref ubuntu26
unset ASSET_TOKEN
```

token 需能写入目标 owner 的 Generic Packages、仓库 Actions variables，并在使用
`--build` 时启动 Actions。也支持从本地私有凭据文件导出
`FORGEJO_ADMIN_USER`、`FORGEJO_ADMIN_PASSWORD`，使用 Basic 认证；无需把密码写在命令中。
若环境同时配置 token 和 Basic 凭据，请明确使用预期账号。

工具将输入发布到 Generic Package Registry，例如：

```text
http://192.168.1.209:3000/api/packages/ubuntu/generic/ubuntu-build-inputs/inputs-<摘要前16位>/ubuntu-build-inputs.tar.zst
```

同时上传 `.sha256`，自动设置仓库 Actions variables：

| 名称 | 内容 |
| --- | --- |
| `BUILD_INPUTS_URL` | 本次完整输入包的下载 URL |
| `BUILD_INPUTS_SHA256` | 完整的 64 位 SHA256 |

`--build` 随后触发选定源码分支。不带它则只上传并更新输入，之后可以在 Actions 网页
选择 **Ubuntu rootfs** 手动运行。平台参数均从输入包中的 `build.json` 读取。
Forgejo 产物在 Actions 的对应运行记录中下载，目前该 workflow 输出文件系统附件，
不会自动发布完整 SDK 镜像到 Release。

## 5. 命令行上传到 GitHub

为目标仓库配置具有 Contents 写权限和 Variables 写权限的 token；使用 `--build`
还需要 Actions 写权限。更新 workflow 源码需要相应 Workflows 写权限。
不需要为了资产上传授予仓库 Administration 权限。

已有私有凭据文件时，在本机 shell 中加载并导出 token；不要使用 `set -x`：

```bash
source ~/.config/hostConfig/local_machine.sh
export GH_TOKEN
python3 scripts/publish-build-inputs.py github \
  --repository bitshelf/Rockchip-Ubuntu --build --ref ubuntu26
```

没有凭据文件时，可先 `read -rsp 'GitHub token: ' GH_TOKEN; echo; export GH_TOKEN`。
脚本也支持 `GITHUB_TOKEN`。示例仓库请替换为自己的 `owner/repository`。

上传工具把输入包和 SHA256 发布为 `inputs-<摘要前16位>` Release 附件，并自动配置
相同的两个 Actions variables。该 Release 是供 CI 下载的依赖，必须保留且保持可下载；
删除或转为私有/草稿会导致后续构建下载失败。输入包改变会生成新的摘要版本，不覆盖旧包。

分支推送和手动运行会生成三种完整可烧录镜像，保存在 Actions artifacts；正式放到
Release 下载界面需要推送一个新的版本标签，例如：

```bash
# 先确认源码提交、外部输入和 config/release/notes.json 均为本次交付内容。
git tag -a v0.1.0-alpha.2 -m 'v0.1.0-alpha.2'
git push origin v0.1.0-alpha.2
```

标签须使用未发布的新版本；不要原样重复已存在的版本。标签构建成功后，在 Release
看到每种产品的 `ubuntu-26.04-<variant>-update.img.zst`、SHA256、JSON 构建记录和
软件包版本 manifest。`desktop` 代表 GNOME，`desktop-xfce` 代表 XFCE。
完整镜像由 ARM64 构建 rootfs 后，交给 x86 runner 运行 SDK 原始打包工具生成；
kernel 和 U-Boot 不在云端重新编译。

## 6. 使用网页上传

网页方式也必须上传**完整输入集合的压缩包**，逐个附加 `.ko`、`.deb` 不会被当前 CI
自动识别。先在本地打包：

```bash
python3 scripts/build-inputs.py pack \
  --output "$PWD/artifacts/ubuntu-build-inputs.tar.zst"
cat artifacts/ubuntu-build-inputs.tar.zst.sha256
```

GitHub：在 Releases 创建 `inputs-<唯一版本>`，上传 `.tar.zst` 和 `.sha256`，发布后
复制压缩包的实际下载链接。在 Settings → Secrets and variables → Actions → Variables
填写 `BUILD_INPUTS_URL` 和 `BUILD_INPUTS_SHA256`，再从 Actions 启动。

Forgejo：可在 Releases 上传相同两个文件，或使用服务支持的 Packages 上传界面。
在仓库 Settings → Actions → Variables 填写同样的 URL 和 SHA256，再手动运行。
网页菜单名称可能随服务版本不同，关键是 CI 能下载该 URL 指向的完整压缩包。

若附件需要认证，另在 Actions **Secrets** 设置 `BUILD_INPUTS_AUTH_HEADER`，值为完整
HTTP 认证头，例如 `Authorization: token <token>`（Forgejo）或
`Authorization: Bearer <token>`（GitHub）。该下载凭据应仅有必要的读取权限。
不要把它填进普通 Variables、build.json 或上传压缩包。

## 7. 验证下载及交付

上传脚本会显示最终 URL、输入版本和完整 SHA256。上传完成后，用与 CI 相同的入口
验证下载和内部清单，目的目录必须尚不存在：

```bash
export BUILD_INPUTS_URL='从上传结果复制实际 URL'
export BUILD_INPUTS_SHA256='从上传结果复制完整 SHA256'
python3 scripts/build-inputs.py fetch --inputs /absolute/path/to/new-input-check
```

下载到的公开 SHA256 文件可辅助检查，但 CI 应固定上传时可信的完整摘要，不能在每次
构建时无条件接受远端新摘要。私有附件还需在当前环境设置 `BUILD_INPUTS_AUTH_HEADER`。

ARM64 返回的文件系统镜像保存为 `ubuntu/artifacts/ubuntu-rootfs.img`，SDK 的
`rockdev/rootfs.img` 链接到它，再按 [SDK-IMAGE-PIPELINE.md](SDK-IMAGE-PIPELINE.md)
执行原有 SDK 打包。GitHub 已输出整包时，校验后使用 `zstd -d` 解压，再用适配目标板
的 SDK 烧录工具写入。可烧录整包不能当作裸 rootfs 用 `dd` 写入。

构建与打包成功不代表硬件验收成功；image、target、reboot、soak、promotion 的实机证据
必须对应本次镜像哈希。回退时重新选择保留的旧输入 URL/SHA256 和匹配的源码版本；
若还需固定 Ubuntu 软件包版本，同时提供旧版本 manifest 及可获得那些版本的软件源。

## 常见问题

| 现象 | 处理 |
| --- | --- |
| 输入下载返回 404 | 检查输入 Release/Package 是否仍存在、附件是否已经发布、URL 是否为实际附件下载地址；私有附件还需下载 secret。不要删除仍被 `BUILD_INPUTS_URL` 引用的版本。 |
| 上传或更新变量返回 403 | 核对 token 是否选择了目标仓库以及 Contents、Variables、Actions 的相应写权限；输入文件无需提交 Git。 |
| DEB 匹配多个版本 | 将旧包移出配置匹配的 SDK 输出目录，每项仅保留本次需要的一个版本，再重新暂存。 |
| KO vermagic 或 headers 不匹配 | 用同一次内核构建的 Image、模块、headers 和最终配置重新生成资产；不要只改文件名。 |
| firmware 校验失败 | 确认本地 SDK 已完成整包打包，备份旧 `artifacts/firmware/` 后重新 stage，不能沿用旧哈希。 |
| CI 成功却没有新 Release | 分支和手动运行只生成 Actions artifacts；发布新镜像须推送合法的新版本标签，并等待三种产品全部构建和打包成功。 |
