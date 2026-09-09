# OTA 功能测试列表

状态只在真实目标板留有日志证据后改为 `✅`；未执行保持 `⬜`。

| 状态 | 功能 | 验收证据 |
|---|---|---|
| ⬜ | `updateEngine --misc=display` 只读检查 | 命令输出、BCB 状态 |
| ⬜ | 非 A/B rootfs 升级 | package-file、串口日志、升级前后版本 |
| ⬜ | boot 分区升级 | `boot.img` 哈希、重启后的 kernel/DTB 版本 |
| ⬜ | U-Boot 分区升级 | `uboot.img` 哈希、U-Boot 版本、冷启动日志 |
| ⬜ | recovery 分区升级 | recovery 版本及进入/退出 recovery 日志 |
| ⬜ | bootfs 独立升级 | extlinux、Image、DTB/DTBO 清单及重启结果 |
| ⬜ | A/B 正常升级 | 当前 slot、目标 slot、切换后的版本 |
| ⬜ | A/B 启动失败回滚 | bootcount/slot 元数据和回滚串口日志 |
| ⬜ | 更新中断电恢复 | 断电点、恢复路径、最终分区哈希 |
| ⬜ | update.img 损坏拒绝 | 损坏方式、updateEngine 错误输出 |
| ⬜ | 分区容量不足拒绝 | payload/分区大小和拒绝日志 |
| ⬜ | factory/recovery 恢复 | 恢复镜像哈希、烧录日志、首次启动结果 |
