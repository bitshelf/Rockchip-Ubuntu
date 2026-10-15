# Forgejo/GitHub ARM64 CI 与构建资产

完整操作步骤见 [kernel、U-Boot、DEB、KO 上传指南](UPLOAD-ASSETS.md)，包含命令行、网页上传和发布验证。

推荐流程见 [ARTIFACTS.md](ARTIFACTS.md)：所有板级选择和 KO、DEB、
内核、DTB、updateEngine 源码输入放在 Git 忽略的 `artifacts/`。
上传目录集合后，CI 从 `build.json` 自动读取平台信息，不需要设置 SoC、
基础 DTB、GPU stack 等 repository variables。

命令行上传工具自动维护 `BUILD_INPUTS_URL`、`BUILD_INPUTS_SHA256`；这是
输入包的位置和身份，不承载板级配置。Forgejo 使用 native-arm64 runner，
GitHub 默认使用 ubuntu-24.04-arm。两者分别构建 Server、GNOME 和 XFCE，输出
rootfs 压缩包、manifest、build-info、QA、EROFS rootfs、ext4 boot/userdata
及 SHA256。CI 附件发布 manifest、构建与 QA 记录及各文件系统镜像，
其中 EROFS 使用稳定名称 `ubuntu-rootfs.img`；基础 tar 压缩包保留在构建输出中。

CI 启动菜单使用 extlinux `timeout 30`，即 3 秒。SDK U-Boot 将此值
换算为整秒；带菜单标题时，低于 10 的值会使菜单无限等待串口输入。
构建门禁检查 CI 生成的启动策略，实机验收还需确认无需串口选择即可启动。

`BUILD_OUTPUT_DIR` 是 Forgejo 主机存储位置的可选运维配置。私有附件使用
secret `BUILD_INPUTS_AUTH_HEADER`，不要将 token 放入仓库变量、Git、
artifacts 清单或验收记录。根文件系统使用原生主机，不放进容器构建。

## 已有 SDK 资产接口

`scripts/stage-sdk-assets.sh` 依照模块和 DEB manifests 暂存 SDK 输出；
`scripts/pack-platform-assets.sh`、`fetch-platform-assets.sh` 保留单平台
资产交换接口。SDK 发布 workflow 仍适用于具有 SDK 输入的独立 runner，
它的 SDK 路径属于 SDK 采集流程，不是新平台 rootfs CI 的配置要求。

`scripts/publish-platform-assets.sh` 支持 GitHub Release、Forgejo Release
与 Forgejo Generic Package Registry。上传前验证 SHA256，Generic 上传后
重新下载验证；同版本同名不同内容拒绝覆盖。新 rootfs CI 使用自包含的
`ubuntu-build-inputs` 包，自动上传工具以内容摘要标识输入版本。

ARM64 回传的 rootfs 放到 `ubuntu/artifacts/ubuntu-rootfs.img`，
`rockdev/rootfs.img` 指向此文件，再使用 SDK 原有打包流程。见
[SDK-IMAGE-PIPELINE.md](SDK-IMAGE-PIPELINE.md)。

## GitHub complete flashable images

Keep the single source branch `ubuntu26`. Build U-Boot, kernel, matching KO,
DEB and vendor inputs locally, then stage them under the ignored `artifacts/`
directory using the existing platform-asset manifest. These binaries are
Release attachments, never Git objects.

After completing the SDK's normal `./build.sh updateimg` once locally, capture
its selected loader, U-Boot, recovery, partition table, package list and tools:

```bash
python3 scripts/pack-firmware.py stage --sdk ..
python3 scripts/pack-firmware.py check
# Load GH_TOKEN privately from your local credential file first.
python3 scripts/publish-build-inputs.py github \
  --repository bitshelf/Rockchip-Ubuntu --build --ref ubuntu26
```

The repository argument selects your destination repository. The SDK argument
selects your local SDK; no board name or SoC CI parameter is required.
`artifacts/firmware/manifest.json` hashes every external packaging input.
The uploader includes this directory alongside `build.json`, platform assets,
source archives and optional overlays. Replacing these local inputs and
uploading a new bundle selects another board/SoC. Do not reuse an incompatible
loader, U-Boot, recovery or partition table from a different board.

GitHub first builds each rootfs on native ARM64, then uses an x86 runner for
the SDK's existing `afptool -pack` and `rkImageMaker` commands. This preserves
the SDK image format without compiling kernel or bootloader in CI. It checks
input SHA256, filesystem integrity, partition capacity and RKFW output header.
Missing firmware inputs fail the job; an ordinary rootfs is not renamed to
`update.img`.

After all variants pack successfully, a final job creates a public prerelease
named `ubuntu26-build-<run>-<attempt>`. Each variant has a complete
`ubuntu-26.04-<variant>-update.img.zst`, SHA256 sidecar and a JSON build receipt.
Check the checksum, run `zstd -d <file>.img.zst`, and use the SDK flashing tool
with the resulting full image. Full-image flashing uses its embedded partition
and loader configuration; select it deliberately rather than treating it as a
rootfs-only update. Automated prereleases report build success separately from
physical board acceptance. Existing accepted release evidence is not reused
for a new image hash.

The workflow token needs `contents: write` to create Releases. The local upload
token needs Contents and Actions Variables write permissions, plus Actions
write permission when requesting `--build`. No credentials go into `artifacts/`
or Git. Large assets are uploaded as streams rather than loaded into RAM.

## 原生构建缓存清理

Forgejo 成功上传 filesystem 附件后，会校验并删除 runner 上重复保存的原始
rootfs 镜像，保留 manifest、校验文件和构建元数据。已上传的 Actions 附件不受影响，
后续打包应下载对应运行的附件。上传失败时不执行此清理。
`clean-cache` 必须显式指定输出目录并设置 `CLEAN_CI_WORK=yes`；两份镜像均通过
SHA256 校验后才删除，拒绝符号链接和校验不一致的文件。
