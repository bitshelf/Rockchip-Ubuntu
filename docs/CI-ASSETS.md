# Forgejo/GitHub platform assets 与 ARM64 native CI

仓库中的 Server 构建不提交 DEB、KO、DTB、DTBO、kernel Image 或 vendor blob。
这些输入统一发布为 `platform-assets-<soc>.tar.zst` 和同名 `.sha256`，Forgejo、
GitHub 与 ARM64 手工构建都调用同一下载/校验脚本。

## 发布任务

`.forgejo/workflows/platform-assets.yaml` 和
`.github/workflows/platform-assets.yaml` 必须运行在能读取 Rockchip SDK 的
self-hosted runner。配置以下 repository variables：

- `SDK_RUNNER_LABEL`：拥有 SDK 工作树的 runner label；
- `SDK_DIR`、`SDK_OUTPUT_DIR`、`SDK_KERNEL_CONFIG`；
- `BUILD_OUTPUT_DIR`、`SOC_MODEL`；
- `PLATFORM_ASSET_RELEASE_TAG`：本批不可变 Release tag。

发布任务由 `config/local-debs/packages.conf` 与
`config/kernel-modules/modules.conf` 选择所有允许发布的输入。Forgejo 还需 secret
`PLATFORM_ASSET_RELEASE_TOKEN`；GitHub 使用 workflow 自带且具有 `contents: write`
的 token。

每个 tag 只允许上传一次。同名资产存在时任务失败，升级或回滚通过选择另一个
Release tag 完成，避免静默替换 CI 输入。

## Server 构建任务

GitHub repository variables：

- `ARM64_RUNNER_LABEL`：可选，默认使用 GitHub ARM64 runner；
- `SOC_MODEL`、`BOOTFS_BASE_DTB`；
- `PLATFORM_ASSET_BUNDLE_URL`；
- `PLATFORM_ASSET_BUNDLE_SHA256`：建议固定，未设置时下载 `.sha256`。

私有 Release 使用 secret `PLATFORM_ASSET_AUTH_HEADER`，例如 GitHub Bearer 或
Forgejo token 的完整 Authorization header。不要把 header 写进 repository
variable。

Forgejo Server workflow 默认运行在 `native-arm64`，可由 runner 环境提供同一组
变量。设置 URL 时下载 Release；不设置时验证
`BUILD_OUTPUT_DIR/platform-assets/<soc>/` 中已有的 bundle，从而保持 209 上手工
构建与 Forgejo runner 共享输出目录的模式。

两套 Server workflow 的实际构建入口相同：

```text
source checks -> fetch/check assets -> server rootfs -> Web artifact
```

Server rootfs、SHA256、manifest、filelist、build-info 和最小 QA JSON 会上传到
对应的 Forgejo/GitHub Actions 运行页。rootfs 本身已经是 `tar.gz`，上传步骤使用
`compression-level: 0`，避免 ARM64 runner 重复压缩；Forgejo runner 到 209
Forgejo 服务走局域网直传。产物保留时间沿用 Forgejo/GitHub 仓库或实例策略，
不在 workflow 中固化。

Server rootfs 仍使用 ARM64 native；Forgejo 在已迁移 OTA 输入的环境继续构建
EROFS/bootfs。GitHub workflow 当前只构建 Server rootfs，等 OTA/updateEngine 独立
提交并加入同一资产契约后再启用完整镜像阶段。发布 platform assets 本身可在 x86
或 ARM64 SDK 主机执行，因为暂存和压缩不运行目标二进制。
