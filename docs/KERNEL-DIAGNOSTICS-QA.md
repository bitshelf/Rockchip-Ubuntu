# kernel log allowlist、pstore、watchdog 验收

`config/kernel/diagnostics.conf` 固定要求 PSTORE RAM/console 和 DesignWare watchdog。
`tests/target/test-kernel-diagnostics.sh` 检查配置、实际 pstore 挂载和 watchdog
身份，输出 `PSTORE_WATCHDOG_PROBE_OK reset_tested=false`。没有
`WATCHDOG_SYSFS` 时使用 `WDIOC_GETSUPPORT`，短暂打开设备后通过 magic-close
停止 watchdog；拒绝 nowayout 配置。探测不能作为实际复位验收。

`tests/target/test-kernel-log-allowlist.sh` 将 error-level dmesg 与锚定 ERE
对比，读不到日志、未锚定规则和新增未审查错误均失败。GPU timeout、Oops
及硬件访问错误不能为通过门禁而扩大匹配规则。

VOP 缺少可选的 `vop-supply` 时，只接受 SDK 明确记录
`Unsupported VOP aclk dvfs` 的固定时钟回退；显示与 GPU 功能仍单独验收。
RX8025 首次冷启动的 `hctosys` 失败仅在 NTP 已同步、RTC 可读且与系统 UTC
时间偏差不超过 60 秒后接受。该检查证明启动后的时间恢复，不证明备用电池
或断电后的时间保持。音频 I²C 访问失败不在白名单内。

受控测试使用 `/usr/libexec/ubuntu-kernel-reset-qa`，要求识别出的 Rockchip 目标板和 root。
开始前确认串口恢复路径、保存当前启动证据及同步数据；测试会中断桌面。
`panic --confirm-reset --evidence /var/lib/ubuntu-hardware-qa/<unique-test>`
写入唯一 kmsg 标记后触发 SysRq panic；重启后 `verify-panic --evidence ...`
要求 boot ID 改变，并在同一 pstore 记录中找到测试标记与 SysRq panic。
同时检查 `/sys/fs/pstore` 和 systemd-pstore 的归档目录，保留测试前日志。

`watchdog-reset --confirm-reset --evidence ... --timeout 15` 设置超时并停止
喂狗，保留设备 FD 等待复位；未复位则停止 watchdog 并失败。
`verify-watchdog` 只记录 boot ID 改变，结果仍为 `passed=false`；主机必须
补齐从最后喂狗到重启的时间窗口及串口复位原因，才能判定 watchdog 通过。
普通重启不能代替 watchdog 到期复位，旧 pstore 崩溃不能代替本次 panic。
