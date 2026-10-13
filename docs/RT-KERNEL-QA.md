# RT kernel、cyclictest 和 industrial fragments

`config/kernel/rockchip_rt.config` 固定 RK3576 PREEMPT_RT 调度选项；
`config/kernel/industrial-recommended.config` 单独保存 pstore、watchdog 和加固建议，
由板级 kernel 配置合并后再构建，不把 industrial 建议误当作默认 Server 配置。

当前 BSP 6.1.141 的 ARM64 没有启用 `ARCH_SUPPORTS_RT`，直接合并片段会
丢失 `PREEMPT_RT`。必须先在独立 SDK 源码副本应用
`docs/patches/kernel/0003-preempt-rt-6.1.141-rt52-rockchip.patch`。
该补丁来自 kernel.org 的同版本 rt52，保留 Rockchip 8250 PTIME/RS485
逻辑，并对额外的 IER 更新应用 RT 串行化。上游压缩补丁 SHA256 为
`441f74b7716b81ef01a17be1797e5ec28065c4271b6784e0426b1a4821726fd6`。
GNOME RT 产品最后合并 `jr3576-gnome-rt.config`，解析后必须确认
`PREEMPT_RT=y`、`ARCH_SUPPORTS_RT=y`、`HZ_1000=y` 和 industrial 加固配置。
运行时同时检查 `/sys/kernel/realtime=1`、`/proc/version` 与实际内核配置；
内核名称包含 `rt` 不能代替这些证据。当前补丁已通过无 fuzz 试应用和
配置解析；实机 cyclictest 结果需要单独记录，不继承历史测试结果。

目标运行 `tests/target/test-rt-cyclictest.sh`。测试绑定 CPU0、SCHED_FIFO 99、
60 秒、50 us histogram 上限，并同时要求最大延迟小于 50 us 且 overflow 为 0，成功标记为 `CYCLICTEST_RT_OK`。验收日志必须保存完整 cyclictest 输出、`uname -a` 和 `/proc/version`。

2026-09-06 目标实测（20 秒快速轮次）最大延迟 2 us、overflow 0，输出保存在 `artifacts/acceptance-20260905/cyclictest-rt-20260906.log`；正式 promotion 仍应使用默认 60 秒或更长 soak 时长。

## JR3576 GNOME CPU7 隔离配置

2026-10-13 的 GNOME RT 常规配置测试在 CPU7 上运行 60 秒，最大延迟
63 us、22 次 histogram overflow，未达到 50 us 门槛；旧批次通过结果不能
覆盖本轮失败。独立候选在 `jr3576-gnome-rt.config` 后合并
`jr3576-gnome-rt-isolated.config`，保留 PREEMPT_RT/HZ1000，并启用
NO_HZ_FULL、RCU offload 和 CPU isolation。解析配置与独立编译已通过。

配套 bootfs policy 为 `config/bootfs/jr3576-gnome-rt-isolated.conf`，固定
CPU7 用于实时任务、CPU0–6 用于桌面和普通 IRQ。必须同时加入
`config/dts/optional/rk3576-rt-isolation.dtso`：它保留串口参数，去掉
SDK `/chosen/bootargs` 的 trailing expedited RCU/`rcu_nocbs=all`，
避免覆盖 extlinux 的显式 `rcu_nocbs=7 rcupdate.rcu_expedited=0`。
这是专用的工业 RT 配置，会减少普通桌面可用的 CPU 调度范围；没有静默
调整验收阈值。

实机冷启动已确认内核 `6.1.141-rt52-rt-isolated-jr3576`、
`isolated=7`、`nohz_full=7`、`rcu_expedited=0`。60 秒测试在浏览器视频
复测同时运行时最大延迟 117 us、overflow 110，失败；随后独立轮次
（期间执行短暂 ALSA 播放/录音诊断）最大延迟 45 us、overflow 0，通过。
因此隔离配置尚未通过并发负载验收，不能以第二轮结果覆盖第一轮失败。
原始日志分别为 SDK 输出 `qa/rt-isolated-idle.log`（历史文件名，实际与
浏览器测试重叠）及 `qa/rt-isolated-standalone.log`，批次目录为
`output/ubuntu-desktop-jr-20261013/`。正式并发 soak 仍需独立实测。

同一 SDK 中 `TOUCHSCREEN_GOODIX` 与 `TOUCHSCREEN_GT9XX` 都注册为
`Goodix-TS`；板级配置保留支持 `goodix,gt911` 的上游驱动，关闭 GT9XX。
该配置变更需在下一次内核构建后确认重复注册日志消失。
