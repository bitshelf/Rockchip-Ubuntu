# 输入目录规范

新版 CI 使用 [ARTIFACTS.md](ARTIFACTS.md) 的自包含输入目录，平台参数由
`artifacts/build.json` 提供。下面的独立 platform-assets 接口仍可手工使用。

# x86 资产 → ARM64 Forgejo rootfs → SDK 整包

`artifacts/` 存放二进制交付输入和输出，不纳入 Git。内核模块保留
`lib/modules/<kernel-release>/` 结构；DEB 保留包名、版本和 arm64 架构。
它们与 Image、DTB、固件一起纳入平台资产 SHA256 清单，不能只复制零散 KO。
源码、配置和补丁提交到 Git，运行记录与带日期的验收材料留在输出目录。

## x86 准备及上传

先用 SDK 构建内核、模块及本地 DEB，然后导出资产：

```sh
export SOC_MODEL=<soc>
export PLATFORM_ASSET_DIR="$PWD/artifacts/platform-assets/$SOC_MODEL"
./scripts/stage-sdk-assets.sh
./scripts/pack-platform-assets.sh
```

`artifacts/platform-assets/<soc>/` 中包含 KO、DEB、启动资产和清单；同目录
生成 `platform-assets-<soc>.tar.zst` 与 SHA256。发布流程
`.forgejo/workflows/platform-assets.yaml` 上传此资产包至 Forgejo Generic Package Registry。
服务器、release tag 与 token 由 Forgejo 变量及 secret 配置，不写入代码。

## ARM64 构建与回传

在原生 ARM64 Forgejo runner 设置 `SOC_MODEL`、资产 URL 和 SHA256、
`BOOTFS_CONFIG` 及所选 GPU stack。`server.yaml` 分别构建 Server 与 GNOME，
使用各自的输出目录，下载同一批已验证平台资产，构建 Ubuntu rootfs，
再生成 EROFS rootfs、ext4 boot 和初始化 userdata，校验后一起上传 artifact。
手工原生 ARM64 构建使用同样的入口与对应输出目录。

## x86 使用 SDK 打包

下载某一个 variant 的 artifact，按以下名称整理到输入目录，并生成该目录的
`SHA256SUMS`：`rootfs.img`（EROFS）、`boot.img`（ext4）、`userdata.img`
（ext4）。重命名前先验证 ARM64 原始 `.sha256` 文件。使用
`generate-factory-parameter.sh` 根据实际镜像大小生成 `parameter.txt`，
将它的 SHA256 同样加入清单。

```sh
./scripts/stage-sdk-firmware.sh /absolute/path/downloaded-firmware --check
./scripts/stage-sdk-firmware.sh /absolute/path/downloaded-firmware
./build.sh updateimg
```

staging 验证输入校验值和文件系统，将 EROFS 复制为
`ubuntu/artifacts/ubuntu-rootfs.img`，并创建
`SDK/rockdev/rootfs.img -> ../../ubuntu/artifacts/ubuntu-rootfs.img`；同时放入本批次 boot、
userdata 和 parameter。已有 SDK 产物移到 `output/ubuntu-firmware-backup/`。
因此应串行打包 Server/GNOME，并立即将每次 `rockdev/update.img` 另存到
`artifacts/<variant>/`，附上校验值，避免下一批覆盖。

SDK 的 Loader、U-Boot、recovery 必须与目标、ext4 boot 和分区布局匹配。
使用 SDK 原生 package-file、afptool 和 rkImageMaker，不维护另一套封装实现。
核对打包日志，至少包含 boot、rootfs、userdata 和 parameter。
整包使用 Rockchip 烧录工具，不是可直接 dd 的磁盘镜像；初始化 userdata 会
清除用户数据。构建与封装成功不等于板级 reboot/soak/promotion 已通过。
