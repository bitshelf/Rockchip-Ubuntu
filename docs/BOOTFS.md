# 独立 bootfs 生成与验证

bootfs 是一个独立的 ext4 产物，只消费已经通过 SHA256 验证的
platform-assets，不读取 SDK `output/`，也不依赖 rootfs 解包目录。生成和验证
均不挂载文件系统、不需要 root 权限，适合在 x86、ARM64 手工环境和 Forgejo
host runner 中执行。构建通过 `fakeroot` 让镜像内文件保持 `root:root`，不会把
构建主机的用户 UID/GID 写进产物。

## 输入与策略

先按 [SDK-ASSETS.md](SDK-ASSETS.md) 暂存并同步板级输入。bootfs 构建使用：

- `boot/Image`；
- `config/bootfs/bootfs.conf` 选择的一个基础 DTB；
- bundle 中的全部 DTBO，它们只被复制到 `/overlays`，不会自动启用；
- 可选的 `BOOTFS_INITRD`，用于后续 initramfs 功能输出。

卷标、容量、基础 DTB、安装名称、启动参数和默认启用 overlay 都属于板级策略，
放在 `config/bootfs/bootfs.conf`，不硬编码在通用脚本中。基础配置不启用任何
overlay；SDK 自带 `extlinux.conf` 可能包含固定 PARTUUID，因此不会被复制。

## 生成

```bash
./scripts/stage-sdk-assets.sh --check
./build.sh bootfs
```

x86 默认产物为 `build/images/bootfs-<soc>.img`，ARM64 默认位于
`/var/lib/ubuntu-ci/build/images/`。若 `.env` 设置了 `BUILD_OUTPUT_DIR`、
`SOC_MODEL` 或 `PLATFORM_ASSET_DIR`，手工构建和 CI 会读取同一位置。

需要带 initrd 时显式指定文件，脚本会增加 `initrd /initrd.img`：

```bash
BOOTFS_INITRD=/absolute/path/to/initrd.img ./build.sh bootfs
```

输出包括：

- `bootfs-<soc>.img`：256 MiB ext4 bootfs；
- `bootfs-<soc>.img.sha256`：完整镜像校验；
- `bootfs-<soc>.img.build-info`：输入 bundle、内核版本和文件系统策略证据。

镜像内布局为：

```text
/Image
/bootfs.manifest.tsv
/dtb/board.dtb
/extlinux/extlinux.conf
/overlays/*.dtbo
/initrd.img                 # 仅设置 BOOTFS_INITRD 时存在
```

`extlinux.conf` 使用 `root=PARTLABEL=rootfs`，不绑定 GPT 分区号或 PARTUUID。
ext4 明确关闭 `orphan_file` 特性，以兼容目标使用的 Rockchip U-Boot 2017.09。

## 独立验收

将镜像、`.sha256` 和 `.build-info` 同步到另一台主机；`.build-info` 用于保留
输入证据，下面的离线验收只消费镜像和 `.sha256`：

```bash
./build.sh bootfs --check
```

验收会检查完整镜像 SHA256、ext4 一致性、容量、卷标、`orphan_file`、
extlinux 的 kernel/DTB/initrd/overlay 引用、DTB/DTBO 格式，以及镜像内 manifest
记录的逐文件 SHA256。整个过程使用 `e2fsck`、`dumpe2fs` 和 `debugfs` 离线读取，
不挂载镜像，也不再需要原始 platform-assets、initrd、模板或镜像生成工具。

Host QA：

```bash
bash tests/host/test-build-bootfs.sh
```

该测试使用临时 platform-assets 生成真实 ext4 镜像，验证 extlinux 内容和
U-Boot 兼容特性，并确认被修改的镜像不能通过 SHA256 验收。

Forgejo 的 Server workflow 在 platform-assets 验收后也会执行
`./build.sh bootfs`；因此 ARM64 CI 会留下同样的 bootfs、SHA256 和 build-info，
然后再构建 Server rootfs。bootfs 与 rootfs 构建失败可以独立定位。
