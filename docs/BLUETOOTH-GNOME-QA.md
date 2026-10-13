# Blueman / BlueZ 实机验收

GNOME 包清单包含 `bluez`、`blueman`、`libspa-0.2-bluetooth`，使用已有
PipeWire/WirePlumber。Server 不引入 Blueman。新增包需要重建镜像，不能将旧镜像
的验收结果沿用为新增蓝牙功能的证明。

在正常 GNOME 用户会话中启动 `blueman-manager`，确认控制器可见并上电。
用真实耳机、音箱、键盘或鼠标测试。在 Blueman 中首次配对并记录 passkey/PIN
提示、用户确认及完成结果。也可在同一个持续运行的 `bluetoothctl` 进程中执行
`agent KeyboardDisplay`、`default-agent`、`scan on`、`pair <MAC>`，完成后
`scan off`。多个单次 bluetoothctl 调用不能保留 agent 的生命周期。

运行连接检查（会信任指定设备，并主动断开、重连）：

```sh
BLUETOOTH_TEST_MAC=AA:BB:CC:DD:EE:FF \
  tests/target/test-bluetooth.sh
```

`BLUETOOTH_RECONNECT_OK` 仅证明已有配对状态、信任及主动重连，不能证明本次
首次配对，也不能代替外设断电重开或目标重启后的自动重连。

音频在 GNOME 用户终端运行，指定已知可听的 WAV：

```sh
BLUETOOTH_TEST_MAC=AA:BB:CC:DD:EE:FF BLUETOOTH_TEST_PROFILE=audio \
  BLUETOOTH_TEST_WAV=/path/to/test.wav tests/target/test-bluetooth.sh
```

脚本按 MAC 选择唯一 BlueZ 输出节点，通过 `pw-play --target` 播放，再要求
现场听音确认。`BLUETOOTH_AUDIO_PLAYBACK_OK` 仅覆盖播放；HFP 麦克风录音、
音质、长时间稳定性必须单独记录，不能由节点存在推断通过。

HID 需安装 QA 工具 `evtest`，并赋予测试用户读取目标输入设备的权限：

```sh
BLUETOOTH_TEST_MAC=AA:BB:CC:DD:EE:FF BLUETOOTH_TEST_PROFILE=hid \
  tests/target/test-bluetooth.sh
```

按键或移动鼠标。脚本通过 sysfs `uniq` 匹配目标 MAC，再要求真实输入事件；
匹配不到时失败，不能退回任意键盘设备。成功标记 `BLUETOOTH_HID_INPUT_OK`。

验收还需分别记录：外设断电重开后的连接与数据通道、目标重启后的连接与数据
通道、Blueman 配对/passkey UI、控制器开关行为。日志与版本、MAC、控制器地址、
boot ID、结果放在忽略目录 `artifacts/`。缺外设或正常 GNOME 会话时记为待测。

旧树有 DisplayPasskey 签名修复和禁止 rfkill 关电补丁。它们尚未迁入当前包：
须先核对 Ubuntu 26 源码是否已修复签名，并由板端证据判断关电问题；不能直接
假定需要禁止用户关闭蓝牙。

参考：[BlueZ bluetoothctl](https://github.com/bluez/bluez/blob/master/doc/bluetoothctl.rst)、
[WirePlumber 目标节点选择](https://pipewire.pages.freedesktop.org/wireplumber/policies/linking.html)。
