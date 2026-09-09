# Rockchip factory parameter 与 update.img

仓库保留一份 Rockchip 原生格式的 `config/factory/parameter.txt`。它使用唯一的 ext4
`boot` 分区，并在 rootfs 之后使用可增长的 userdata。板型不同时通过 `.env` 的
`FACTORY_PARAMETER_FILE` 选择对应 parameter，不在生成脚本中判断 SoC。

## 动态布局

EROFS 负载大小在每次构建后才能确定：

```bash
./scripts/generate-factory-parameter.sh \
  /absolute/path/rootfs.erofs.img \
  /absolute/path/boot.img \
  /absolute/path/parameter.txt
```

脚本按实际镜像大小调整 `boot` 容量，并将 rootfs 容量按 `ROOTFS_ROUND_MB`
向上对齐，顺延后续 recovery、backup、rootfs 和 userdata 的位置。
保留 boot 之前的 uboot、misc 区域；不插入第二个 bootfs 分区。

没有 rootfs 最大值、最小值或另一份固定分区数组。容量是否适合具体介质由烧录前
的整机容量检查决定。

## 使用 SDK 打包

把生成的 parameter 和本批次镜像放入 SDK `output/firmware/`，然后使用 Rockchip
原生命令：

```bash
./build.sh edit-package-file
./build.sh updateimg
```

`edit-package-file` 打开的 SDK 清单必须显式包含本次 Ubuntu 布局，至少确认以下三项
存在后再保存；仅在 `parameter.txt` 中增加分区不会自动把镜像加入 `update.img`：

```text
boot      boot.img
rootfs    rootfs.img
userdata  userdata.img
```

打包完成后还要检查 SDK 输出的最终 `Image/package-file`，并以 `afptool` 日志确认三项
镜像均出现 `Add file ... done`。缺少任一项的 `update.img` 不得烧录。

Ubuntu 的 `build.sh` 会把这两个命令转交 `SDK_DIR/build.sh`。package-file、loader
tag、`afptool`、`rkImageMaker` 均由 SDK 实现；仓库不复制打包工具，也不维护第二套
RKFW 封装代码。

## 单一启动资产

factory 包中的 `boot.img` 必须来自 Ubuntu 的 ext4 `boot-<soc>.img`，而不是
SDK kernel 目录中的 FIT。它承载 extlinux、Image、initrd、DTB/DTBO。
rootfs 是 EROFS lower，userdata 是首次安装的 OverlayFS upper。

旧布局的 boot 只有 64 MiB，不能容纳新的 256 MiB 文件系统；必须使用新 parameter
进行 factory 迁移。不能将改变 GPT 当作普通 OTA。启动与 recovery 验收要求见
[内核升级设计](BOOT-UPDATE-DESIGN.md)。

## 烧录回读

本 SDK 的 U-Boot `cmd/rockusb.c` 在读取超过 32 MiB 的地址时返回 `0xcc` 填充，
同时报告读取成功。因此通过该 U-Boot rockusb 执行 `upgrade_tool RL`，不能用于
recovery、rootfs 或 userdata 的备份与回读验收。

使用 U-Boot `ums 0 mmc 0` 暴露目标 eMMC，再核对主机新增 USB 磁盘的型号、容量和
GPT 分区标签，从该磁盘读取实际内容并比较镜像 SHA256。退出 UMS 前先卸载主机上
挂载的目标分区。完整升级包烧录后，还须核对新 GPT 的分区起点与容量，再启动系统。
