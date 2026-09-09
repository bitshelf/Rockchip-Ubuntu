# Rockchip updateEngine 与 update.img

Ubuntu 直接使用 SDK `external/recovery/update_engine` 构建出的
`/usr/bin/updateEngine`，不再增加安装命令的二次封装。Debian 包只补充 Ubuntu
需要的 `/dev/block/by-name/<PARTLABEL>` udev 链接。

## 打包入口

仓库根目录的命令直接转交 `SDK_DIR/build.sh`：

```bash
./build.sh edit-package-file
./build.sh edit-ota-package-file
./build.sh updateimg
./build.sh ota-updateimg
```

因此 package-file 生成、A/B 判断、loader tag、`afptool` 和 `rkImageMaker` 都由
Rockchip SDK 维护。不要在本仓库复制另一份打包实现。

打包前，把本批次 Ubuntu 产物放到 SDK `output/firmware/` 对应名称，并使用同一份
`parameter.txt`：

```text
rootfs.img      EROFS lower
boot.img        唯一的 ext4 /boot 文件系统（Ubuntu 产物）
userdata.img    factory 首次烧录使用
parameter.txt   scripts/generate-factory-parameter.sh 的输出
```

SDK 已生成的 `MiniLoaderAll.bin`、`uboot.img`、`misc.img`、
`recovery.img` 保持原路径。用 `edit-package-file` 或
`edit-ota-package-file` 明确选择本次要升级的分区，然后再打包。

## 非 A/B 与 A/B

分区能力不在 Ubuntu 脚本中写死：

- 非 A/B 使用普通 `parameter.txt`，package-file 可以包含 uboot、boot、recovery、
  rootfs 等引擎支持的分区；
- A/B 由 SDK `RK_AB_UPDATE` 和带 `_a/_b` 的 parameter 决定；
- `ota-updateimg` 在 A/B 模式下沿用 SDK 规则，不把 `*_b` 重复装入 A/B OTA 包；
- 是否更新 U-Boot、boot、DTB 或 rootfs，以最终 package-file 为准。

package-file 决定镜像携带的内容，updateEngine 自身的分区表和调用 mask
共同决定实际写入的分区，二者不能混同。Ubuntu 不再增加独立 `bootfs` 分区；
唯一的 `boot` 为 ext4，挂载到 `/boot`。updateEngine 更新其镜像，即更新实际
启动的内核、initramfs 和设备树。不得混入 SDK 原有的 FIT `boot.img`。
内核与 rootfs 中的 modules 必须配套，整体写入在 recovery 中执行。
布局与迁移限制见 [内核升级设计](BOOT-UPDATE-DESIGN.md)。

切换 A/B 布局属于整机启动链路变更，必须同时验证 U-Boot slot、misc/BCB、
recovery 和回滚策略。

## 目标板执行

只读检查：

```bash
sudo tests/target/test-update-engine.sh
```

实际升级直接按 Rockchip 文档调用 `updateEngine`。参数、分区 mask、镜像路径和是否
进入 recovery 必须来自当前 SDK 的说明与本次 package-file，不在本文给出固定值。
执行前至少保存 update.img SHA256、parameter.txt、package-file、当前 slot 和串口
恢复通道。

升级包存放在 `/userdata/` 下，并将这个路径传给 updateEngine。Ubuntu 的
`/userdata` 指向持久分区挂载点 `/var/lib/overlay-root`；recovery 直接将同一分区
挂载到 `/userdata`，因此 BCB 中的文件路径在重启后仍然有效。不要把需要跨重启的
升级包放在 `/tmp` 或根目录 OverlayFS 的普通路径中。

功能验收记录见 `docs/OTA-QA-CHECKLIST.md`。该测试需要真实目标板、掉电控制和恢复
通道，不作为 host 自动化脚本运行。

`--misc=display` 成功读取时返回 0，读取失败返回非零；该只读分支直接返回，
不会因组合 `--reboot` 触发重启。补丁同时限制 BCB 定长字符串的打印长度，
避免未终止字段越界读取。读 BCB 通过不等于实际 OTA 升级或掉电恢复验收通过。

块设备 payload 写入前通过 `BLKGETSIZE64` 检查容量，过大时返回错误，避免写到
分区末尾才失败。该检查针对单次块写入，不提供多分区事务或自动回滚。

实机记录见 [2026-09-06 updateEngine 验收](QA-UPDATEENGINE-20260906.md)。
