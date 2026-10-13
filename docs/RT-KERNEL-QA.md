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
GNOME RT 产品最后合并 `rk3576-desktop-rt.config`，解析后必须确认
`PREEMPT_RT=y`、`ARCH_SUPPORTS_RT=y`、`HZ_1000=y` 和 industrial 加固配置。
运行时同时检查 `/sys/kernel/realtime=1`、`/proc/version` 与实际内核配置；
内核名称包含 `rt` 不能代替这些证据。当前补丁已通过无 fuzz 试应用和
配置解析；实机 cyclictest 结果需要单独记录，不继承历史测试结果。

目标运行 `tests/target/test-rt-cyclictest.sh`。测试绑定 CPU0、SCHED_FIFO 99、
60 秒、50 us histogram 上限，并同时要求最大延迟小于 50 us 且 overflow 为 0，成功标记为 `CYCLICTEST_RT_OK`。验收日志必须保存完整 cyclictest 输出、`uname -a` 和 `/proc/version`。

## RK3576 桌面 CPU7 隔离配置

在 `rk3576-desktop-rt.config` 后合并 `rk3576-desktop-rt-isolated.config`，
启用 NO_HZ_FULL、RCU offload 和 CPU isolation。CPU 编号与启动参数必须来自
具体硬件的 bootfs policy；不同 SoC 不继承其他目标的 CPU 拓扑或测试结果。
同时核对 SDK `/chosen/bootargs` 与 extlinux 参数，防止后者被覆盖。

隔离配置会减少普通桌面可用的 CPU 调度范围。分别记录独立轮次与 GPU、视频、
NPU 并发负载轮次的最大延迟和 overflow；独立轮次通过不能覆盖负载轮次失败。
正式 promotion 还需完整时长 soak。运行记录保存在 Git 忽略的输出目录。
