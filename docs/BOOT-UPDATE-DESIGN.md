# 内核启动与镜像升级

当前迁移目标是单一 ext4 `boot` 分区，挂载到 `/boot`。内核、initramfs、基础 DTB、
DTBO 和 extlinux 配置都在这里。`bootfs` 只是构建脚本中“boot 文件系统”的简称，
不再表示第二个 GPT 分区；产物名称为 `boot-<soc>.img`。

正常启动使用 U-Boot 的 extlinux 文件系统启动。更新包把该 ext4 镜像作为 `boot`
payload，updateEngine 在 recovery 中更新实际启动的 boot 和配套 rootfs。
不能保留另一份优先启动的内核，也不能将旧 SDK FIT boot.img 混入此布局。

这是基于现有 U-Boot、updateEngine 和 EROFS 约束的项目选择，并非声称 Ubuntu
Server 所有平台统一采用 raw 分区 OTA。普通 Ubuntu Server 的包式更新依赖内核包、
initramfs 与引导程序安装钩子；本产品选择整镜像升级，因此发布单元必须同时约束
boot 内核版本和 rootfs `/lib/modules/<release>`。

依据：[U-Boot extlinux](https://docs.u-boot.org/en/stable/develop/bootstd/extlinux.html)、
[RAUC slot 与启动集成](https://github.com/rauc/rauc/blob/master/docs/basic.rst)。
这里只参考更新资产分组原则，不引入 RAUC 替换 updateEngine。

## 必须验证的边界

- U-Boot 必须优先处理 recovery 请求，不能被正常 extlinux 路径截走。
- 运行中的 `/boot` 不做整分区覆盖；boot/rootfs 更新由独立 recovery 执行。
- payload、目标分区容量、内核和 modules 配套关系在发布时检查。
- 单槽更新不具备 A/B 的原子切换、自动回滚保证；RESET 测试不等于掉电测试。
- GPT 改布局必须通过 factory/recovery 迁移，不能直接把 256 MiB ext4 boot
  写入旧 64 MiB boot 分区。旧双布局的 OTA 测试结果不能替代新布局验收。

当前状态：分区生成与镜像命名已调整；新布局实机启动和 recovery 联动验收进行中。
