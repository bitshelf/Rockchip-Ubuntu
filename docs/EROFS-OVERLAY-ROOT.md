# EROFS lower、userdata OverlayFS 与掉电恢复

## 启动契约

根文件系统由三个独立产物组成：

- GPT `PARTLABEL=rootfs`：未压缩 EROFS，只读 golden lower；
- GPT `PARTLABEL=userdata`：ext4，保存 OverlayFS `upper` 和 `work`；
- GPT `PARTLABEL=boot`：ext4，保存 Image、initrd、DTB、DTBO 和 extlinux。

extlinux 使用 `root=PARTLABEL=rootfs rootfstype=erofs rootwait ro`。initramfs 在
`switch_root` 前按 `config/overlay-root/overlay-root.conf` 查找 userdata，不依赖
`mmcblk` 编号。合成后的 `/` 是 OverlayFS；只读 lower 暴露为 `/.rootfs-ro`，
userdata 的诊断入口为 `/var/lib/overlay-root`。应用和服务仍使用标准 `/etc`、
`/var/lib` 等路径，不应直接写这个诊断入口。

userdata 必须由镜像构建阶段格式化。initramfs 遇到未知或无法识别的文件系统会
进入紧急模式，绝不会自动执行 mkfs；这样掉电导致的损坏不会被误判为空盘并
静默清空。已识别的 ext4 会先执行离线 `e2fsck -pf`，再用 `resize2fs` 扩展到
实际分区容量，最后才作为 upper 挂载。

## 内核配置移植

`config/kernel/overlay-root.conf` 是跨板卡的 config fragment，同时也是最终
`.config` 的验收清单。移植到其他内核版本时，在 SDK 内核树执行等价操作：

```bash
kernel/scripts/kconfig/merge_config.sh -m \
  kernel/.config ubuntu/config/kernel/overlay-root.conf
make -C kernel ARCH=arm64 olddefconfig
ubuntu/scripts/check-kernel-config.sh kernel/.config
```

实际 SDK 命令可替换，但验收对象必须是最终 `kernel/.config`，而不是某个可能被
后续 fragment 覆盖的 defconfig。EROFS、ext4、OverlayFS 都必须 built-in；压缩
EROFS 当前禁用，因此切换压缩算法前必须单独验证内核解压支持。

`stage-sdk-assets.sh` 把最终 config、`modules.builtin` 和
`modules.builtin.modinfo` 放入可校验 bundle。当前 RK3576 最终 config 已通过
全部要求，不需要修改 EROFS/VFS/OverlayFS 内核源码。

## 构建和离线验收

```bash
./build.sh server
./scripts/stage-sdk-assets.sh --check
./build.sh overlay-root
./build.sh overlay-root --check
```

脚本从 `images/` 动态发现唯一的 `*.rootfs.tar.gz`，也可通过
`ROOTFS_TARBALL` 指定。EROFS、userdata、initramfs 和 bootfs 的最终合成只允许
在 ARM64 原生主机执行；x86 不通过 QEMU 代替这一步验收。

主要输出：

- `*.rootfs.erofs.img`、`.sha256` 和 `.build-info`；
- `userdata-<soc>.img` 和 `.sha256`；
- `bootfs-<soc>.img`、`.sha256` 和 `.build-info`，其中包含 `/initrd.img`。

userdata seed 默认 64 MiB，烧录到更大的 userdata 分区后由 initramfs 使用
Ubuntu 26 配套的 e2fsprogs 扩容。`overlay-root --check` 验证 EROFS、
ext4、全部 SHA256、bootfs 和 initrd 内的脚本、配置及恢复工具，全程不挂载镜像。

Host QA：

```bash
bash tests/host/test-kernel-config.sh
bash tests/host/test-overlay-root.sh
```

后者会构造一个 dirty ext4 userdata，执行与 initramfs 相同的 preen 流程并扩容，
确认恢复后文件系统为 clean。

## 目标板掉电恢复 QA

只在可重新烧录、已经安排串口或 recovery 通道的测试板执行。不要在保存客户
数据或承担 Forgejo 服务的主机上直接断电。

1. 烧录匹配的 rootfs、userdata 和 bootfs，启动后运行：

   ```bash
   sudo tests/target/test-overlay-power-loss.sh prepare
   ```

2. 启动循环写入，看到持续磁盘活动后由外部继电器直接切断电源：

   ```bash
   sudo tests/target/test-overlay-power-loss.sh write-loop
   ```

3. 重新上电并验收：

   ```bash
   sudo tests/target/test-overlay-power-loss.sh verify
   ```

通过标志为 `POWER_LOSS_OVERLAY_OK=<token>`。验收覆盖 OverlayFS 根、EROFS lower、
ext4 backing、已同步 baseline、upper copy-up、已完成记录无 torn write，以及内核
日志中没有 ext4/OverlayFS/I/O error。每次 `prepare` 生成新 token；正式准入至少
重复 20 次，并保存每轮串口启动日志和 token。24/72/168 小时 soak 属于后续完整
系统准入，不由本功能伪造。

cloud-init 的 growpart/resizefs 在 EROFS 合成阶段禁用：根目录是 OverlayFS，
不能对 `/dev/overlay` 扩容。userdata 扩容由 initramfs 的离线 e2fsprogs 流程负责，
基础 rootfs tarball 的通用 cloud-init 行为不受影响。

写入探针先 fsync 临时记录，再 rename 并同步目录，确保“已完成记录”具有真实的
持久化语义。每条记录带本轮 token，旧轮记录不能满足本轮验收；校验同时检查
头尾 token、序号及完整长度。RESET 只能证明硬复位恢复，不能标记为真实断电通过。
