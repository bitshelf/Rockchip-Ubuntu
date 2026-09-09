# Rockchip U-Boot 启动补丁

U-Boot 和 recovery 在本机 x86 SDK 构建副本编译；Ubuntu rootfs 在 ARM64
构建机编译。补丁保存在本仓库，在 SDK 构建副本应用。

| 补丁 | 应用根目录 | 用途 |
|---|---|---|
| `0001-rockchip-extlinux-fdtoverlays.patch` | SDK `u-boot/` | extlinux、DTBO 和显式 root 参数 |
| `0002-honor-recovery-before-distro-boot.patch` | SDK `u-boot/` | recovery 请求优先于正常 extlinux 启动 |
| `0003-load-early-dtb-from-boot-partition.patch` | SDK `u-boot/` | 驱动探测前按 GPT boot 名称读取 ext4 内的 DTB |

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

## 独立 ext4 bootfs 的早期 DTB

独立 bootfs 没有 RKIMG resource，必须启用早期 distro DTB 并指定
`/dtb/board.dtb`。`0003` 用 GPT `boot` 名称选择分区，避免旧实现只扫描
legacy-bootable 分区而回退到 uboot 分区。使用外部 SDK 中与目标板匹配的 defconfig，并在
构建副本合并 `config/bootfs/extlinux-early-dtb.config`，随后运行 olddefconfig
和 SDK 配套 `make.sh`。配置片段必须复制到构建副本并纳入生产构建输入。

板级 ADC 下载键须由外部 SDK 的实际硬件配置决定。核对 U-Boot 和内核 DTB
中的节点状态及预重定位绑定是否一致；没有装配按键时才禁用相应节点，
不得将某块板的禁用补丁应用到其他产品。保留实际可用的恢复入口并单独验收。

Loader 的读回能力须实测确认，固定填充值不能作为有效回读证据。若不支持
完整分区读取，可启动后核对 bootfs 各 payload 及只读 rootfs 的完整 SHA256，
同时保存实际写入范围、工具日志、镜像与运行版本的对应关系。

## 审核后的应用序列

按 `series` 记录的唯一顺序应用，避免重复叠加 overlay 支持。
`0005` 支持独立 bootfs 中的两个 BMP logo，保留旧 RKIMG 文件缺失回退。
`0001` 的普通 extlinux 优先策略只用于未启用 AVB/FIT 签名校验的配置；
启用这些校验时保持厂商校验启动路径，不将普通 extlinux 视为可信启动实现。

审核后的失败处理：

- overlay 环境地址缺失、格式错误或两地址相同时拒绝当前条目。
- 检查内存分配、DTB/DTBO 头、DTB 扩容及 overlay 应用的返回值。
- overlay 加载或应用失败时停止当前 extlinux 条目；不会带着部分应用的设备树继续启动它。
- 沿用上游多个 overlay 的顺序和空格分隔语义，不另写解析器。
- 早期 DTB 读取检查设备环境变量和分区参数的长度。
- logo 文件不存在时可以回退；分区选择、文件大小查询或读取错误返回失败。

这些修改是对旧 SDK 的启动适配和缺陷修正，不等同于安全启动、功能安全、
升级掉电恢复或工业实时性的认证。GPIO、电源时序和板级 DTS 不由本序列修改。
已有 SDK 代码若包含等价修改，先反向检查各补丁，不要重复叠加。

主机失败处理测试：`bash tests/host/test-uboot-overlays.sh`。
完整验证还需实际编译、正常启动、正确/错误 DTBO、缺失文件及 recovery 入口测试。

## 上游来源与本地适配边界

Overlay 解析/应用以 U-Boot `v2026.10` 的
[`boot/pxe_utils.c`](https://github.com/u-boot/u-boot/blob/v2026.10/boot/pxe_utils.c)
为来源，保留其处理流程；最初引入提交为 `69076dff2284`。
旧 SDK 的 `cmd_tbl_t`、文件加载接口与新上游不同，需要做接口回移。
地址、分配、扩容检查及失败返回是本地审核补充，不冒称已被上游合入或已通过实机验收。

Recovery、早期 DTB 和独立 logo 补丁是针对旧 Rockchip SDK 的本地集成，
没有对应的通用上游移植提交。它们依赖独立 ext4 bootfs 的布局，不能无条件移植到其他 SDK；
须保留来源说明和目标验证，不能将本地主机测试描述为上游或工业认证。
