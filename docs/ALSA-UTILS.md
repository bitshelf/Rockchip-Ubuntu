# alsa-utils 基础 CLI QA

Ubuntu Server 默认安装发行版提供的 `alsa-utils`。镜像构建同时安装
`/usr/libexec/ubuntu-alsa-cli-qa`，用于确认 ALSA 用户态命令与内核枚举接口可用。

目标板执行：

```bash
sudo /usr/libexec/ubuntu-alsa-cli-qa
```

脚本检查 `alsactl`、`aplay`、`arecord`、`amixer` 的版本入口，读取
`/proc/asound/cards`、`/proc/asound/pcm`，并通过 `aplay -l`、`arecord -l` 和
`amixer -c 0` 验证至少一张声卡、播放 PCM、采集 PCM 与 mixer control。通过时输出：

```text
ALSA_CLI_OK cards=<n> playback=<n> capture=<n> controls=<n>
```

这是非破坏性的基础 CLI 验收：不改变 mixer、不播放扬声器、不采集麦克风数据。
声道映射、UCM profile、音量策略和真实播放/录音应在后续 audio UCM 功能提交中独立
验收。
