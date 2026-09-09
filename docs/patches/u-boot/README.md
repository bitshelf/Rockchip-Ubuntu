# Rockchip U-Boot 启动补丁

U-Boot 和 recovery 在本机 x86 SDK 构建副本编译；Ubuntu rootfs 在 ARM64
构建机编译。补丁保存在当前 本仓库，在 SDK 构建副本应用。

| 补丁 | 应用根目录 | 用途 |
|---|---|---|
| `0001-rockchip-extlinux-fdtoverlays.patch` | SDK `u-boot/` | extlinux、DTBO 和显式 root 参数 |
| `0002-honor-recovery-before-distro-boot.patch` | SDK `u-boot/` | recovery 请求优先于正常 extlinux 启动 |

先核对构建副本的基线，使用 `patch --dry-run -p1` 检查，再按顺序应用。
已经包含某补丁的源码可用 `patch --dry-run -R -p1` 核实，不要重复应用。

`0002` 在 `setup_boot_mode()` 中处理 `BOOT_MODE_RECOVERY`，仅修改内存中的
`bootcmd` 为厂商 recovery 启动路径。它不调用 `saveenv`，正常启动仍使用
`0001` 的 distro/extlinux 流程。reboot 寄存器和 misc BCB 两条入口均需验收。

使用 SDK 配套 x86 交叉工具链，经 `./build.sh loader` 构建 U-Boot，
经 `./build.sh recovery` 构建 recovery。构建副本须保留 SDK 根目录链接、
板级配置、rkbin 和所需内核/Buildroot 输入。

编译成功后核对 FIT 内容、SHA256 和目标分区容量；备份原分区，烧录后
完整回读比较。通过串口核对运行版本，验证正常 extlinux 启动、
`reboot recovery`、misc BCB recovery 以及退出 recovery 后的正常启动。

recovery 入口通过不代表 boot/rootfs OTA 已通过。统一 ext4 boot 的分区迁移、
配套内核与 modules、更新执行和失败恢复另行验收；具体设备结果保存在
Git 忽略的 `artifacts/` 中。
