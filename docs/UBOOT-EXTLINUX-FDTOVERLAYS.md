# U-Boot extlinux/FDTOVERLAYS 移植

## 功能

在 RK uboot-2017 合入补丁到 uboot：

```text
docs/patches/u-boot/0001-rockchip-extlinux-fdtoverlays.patch
```

将 PXE/extlinux 实现在 `cmd/pxe.c` 的 Rockchip U-Boot 2017.09
vendor 树。


## 补丁包含的改动

| 改动 | 目的 | 移植属性 |
| --- | --- | --- |
| extlinux 优先、RKIMG 回退 | 标准 bootfs 可启动，同时保留恢复路径 | Rockchip 通用 |
| 扫描所有文件系统分区 | 不依赖 GPT legacy-bootable 标志 | Rockchip 通用 |
| 解析并顺序应用 `FDTOVERLAYS` | 在 U-Boot 启动内核前合并 DTBO | 旧 PXE 实现通用 |
| `fdtoverlay_addr_r=0x48000000` | 提供临时 DTBO 加载区 | RK3576 板级 |
| 保留 extlinux 的 `root=` | 防止 vendor DTB bootargs 覆盖显式根分区 | Rockchip 通用 |
| 删除 `distro_boot_first` wrapper | 避免公共启动路径与旧板级入口嵌套 | 当前基线 |

最终启动顺序为：

```text
CONFIG_BOOTCOMMAND
  -> distro_bootcmd
       -> 文件系统分区中的 /extlinux/extlinux.conf
       -> Image/initrd/基础 DTB
       -> 按配置顺序加载并合并 FDTOVERLAYS
  -> extlinux 未启动时继续 boot_android/boot_fit/bootrkp
```

## 应用与回滚

先指定目标 U-Boot 仓库，补丁路径使用 本仓库的绝对路径：

```bash
UBOOT_DIR=/path/to/sdk/u-boot
PATCH=/path/to/ubuntu/docs/patches/u-boot/0001-rockchip-extlinux-fdtoverlays.patch

git -C "$UBOOT_DIR" apply --check "$PATCH"
git -C "$UBOOT_DIR" apply "$PATCH"
```

回滚前同样先检查：

```bash
git -C "$UBOOT_DIR" apply --reverse --check "$PATCH"
git -C "$UBOOT_DIR" apply --reverse "$PATCH"
```

`git apply --check` 失败时不能使用 `--reject` 或降低上下文强行套用，应按下面的
版本差异逐项移植并重新生成补丁。

## 移植到其他 U-Boot 版本

### 1. 确认 PXE 代码布局

旧 Rockchip 树把 label、token 和加载逻辑集中在 `cmd/pxe.c`。较新的 U-Boot
已经拆分到 `boot/pxe_utils.c`、`include/pxe_utils.h` 等文件，并可能已经支持
`FDTOVERLAYS`。如果目标版本已有该功能，只移植 Rockchip 启动路径和板级加载
地址，不要重复回移解析器。

### 2. 检查配置

最终配置至少应包含：

```text
CONFIG_DISTRO_DEFAULTS=y
CONFIG_CMD_PXE=y
CONFIG_CMD_EXT4=y
CONFIG_CMD_FS_GENERIC=y
CONFIG_OF_LIBFDT=y
CONFIG_OF_LIBFDT_OVERLAY=y
```

这些配置可能来自 Kconfig 默认值、defconfig 或 fragment；应检查构建后的
`.config`，不能只搜索 defconfig。

### 3. 重新计算内存地址

`0x48000000` 是 RK3576 内存布局。移植到其他 SoC/板卡时，应结合
`bdinfo`、U-Boot 环境和最终镜像大小核对：

- U-Boot、malloc、ATF、OP-TEE 和安全内存；
- `kernel_addr_r`、`fdt_addr_r`、`ramdisk_addr_r`；
- 单个 DTBO 的最大尺寸以及 FDT 扩容空间；
- 地址范围在热启动和冷启动时均不重叠。

### 4. 保留回退路径

通用逻辑应修改公共 `RKIMG_BOOTCOMMAND`，先执行 `distro_bootcmd`；extlinux
返回后再进入原有 vendor 启动命令。不要绑定 `mmc 0`、固定分区号或需要
`saveenv` 才能生效的私有开关。

## extlinux 配置示例

基础 DTB 必须带 `-@` 生成的 `__symbols__`。bootfs 示例：

```text
/Image
/initrd.img
/dtb/board.dtb
/overlays/board.dtbo
/overlays/customer.dtbo
/extlinux/extlinux.conf
```

`extlinux.conf` 中按覆盖顺序填写：

```text
LABEL ubuntu
    LINUX /Image
    INITRD /initrd.img
    FDT /dtb/board.dtb
    FDTOVERLAYS /overlays/board.dtbo /overlays/customer.dtbo
    APPEND root=PARTLABEL=rootfs rootwait
```

后面的 overlay 可以覆盖前面 overlay 已设置的属性。U-Boot 合并后 Linux 只
接收最终 DTB，因此该启动方式不要求 Linux 运行时启用 configfs overlay。

## 构建与最小 QA

在目标 SDK 中完成补丁预检后重新构建 U-Boot。当前 Rockchip SDK 可使用：

```bash
./build.sh uboot
```

U-Boot 阶段至少检查：

```text
printenv bootcmd
printenv fdtoverlay_addr_r
run distro_bootcmd
```

目标板验收必须覆盖：

1. 有效 extlinux 配置正常启动并按顺序应用多个 DTBO；
2. 删除或改名 `extlinux.conf` 后仍能回退 RKIMG；
3. DTBO 缺失、损坏及符号 fixup 失败能从串口日志识别；
4. `/proc/cmdline` 保留 extlinux 中的 `root=`；
5. 通过 `/proc/device-tree` 或对应设备节点确认 overlay 的实际效果；
6. 热重启和断电冷启动结果一致。

仅通过 `git apply --check` 和编译不能证明加载地址安全或 overlay 在目标板生效。
