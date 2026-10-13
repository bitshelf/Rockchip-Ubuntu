# GNOME 音频、UCM2 与 WirePlumber

GNOME 桌面使用 Ubuntu 的 PipeWire/WirePlumber 会话服务。板级 UCM2 只描述
codec、HDMI 和 DP 的 ALSA verb/PCM 映射；WirePlumber drop-in 将
`api.alsa.card.longname` 显示为稳定的 Rockchip 卡名。对于这些 HDMI/DP stereo
profile，`api.acp.pro-channels=2` 限制 Pro Audio 的探测声道数，避免控制器的
最大声道数超过连接接收端的 speaker allocation。该设置保留 profile 选择和
实际 stereo PCM 播放，不通过日志 allowlist 隐藏声道映射错误。属性定义见
[PipeWire 官方文档](https://docs.pipewire.org/page_man_pipewire-props_7.html)。

`config/customization/audio/ucm2/conf.d/` 包含 RK3576 常见 HDMI、DP 和 codec
配置，`scripts/install-audio-customization.sh` 将其安装到 `/usr/share/alsa/ucm2`，
并安装 Resolute 的 `wireplumber.conf.d` 规则。镜像必须同时安装 `alsa-ucm-conf`；
GNOME 变体还必须安装 `pipewire`、`pipewire-pulse`、`wireplumber` 和 `alsa-utils`。
这些桌面包不加入 Server seed，避免把桌面会话带入 Server 镜像。

主机静态检查：

```bash
bash tests/host/test-audio-customization.sh
```

目标板真实 I/O：

```bash
sudo /usr/libexec/ubuntu-audio-real-qa
```

该 QA 从 `aplay -l` 和 `arecord -l` 动态取得设备映射，播放短 PCM 正弦波并录制
两秒 PCM，检查录音文件确实有数据。它不假定 `card0`、`device0`，也不把
`aplay -l` 枚举当成真实播放成功。

GNOME 会话中还需检查：

```bash
wpctl status -n
wpctl inspect @DEFAULT_AUDIO_SINK@
alsaucm -c rockchip-hdmi open hw:<card> list _verbs
alsaucm -c rockchip-dp0 open hw:<card> list _verbs
alsaucm -c rockchip-es8388 open hw:<card> list _verbs
```

验收必须记录 HDMI/DP connector、EDID/mode、ALSA longname、UCM verb、WirePlumber
默认 sink，以及实际播放/录音命令和返回值。没有连接显示器或没有 codec 麦克风时，
对应路径记录为未执行，不能伪造通过。Weston 不属于本提交。

ES8389 保持供电的系统还需验收普通软件重启。SDK 驱动的深度关机序列会隔离
控制接口，导致下一次启动 I²C 访问返回 `-ENXIO`；冷启动正常不能覆盖该问题。
对应补丁保存在
[0006-es8389-preserve-powered-codec-on-restart.patch](patches/kernel/0006-es8389-preserve-powered-codec-on-restart.patch)。
在独立 SDK 源码副本中应用补丁，重建内核、模块与匹配的 ARM64 headers DEB，
通过平台资产目录传递，保持原 SDK 源码不变。补丁只在 `SYSTEM_RESTART` 时
跳过深度关机，仍取消延迟工作；halt/power-off 保留原来的关闭序列。

先断电冷启动一次，随后连续普通重启至少三次，每次保存不同的 boot ID、
芯片 ID、真实播放/录音返回值以及完整内核日志。任何 codec/I²C 访问错误均
判定失败。最终还必须在使用该内核资产的 CI 镜像上重复验收。
