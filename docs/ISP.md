# Rockchip RKISP/RKAIQ 服务

RK3576 的内核 `rkisp`、rkcif 和 OV13855 驱动由 SDK kernel 提供；Ubuntu rootfs
安装 rkaiq 作为 ISP3.x 的 3A 引擎。旧 `camera-engine-rkisp` DEB 仅作为旧 ISP
管线的回退输入保留，默认禁用其服务，避免两个 3A 引擎同时控制 media graph。

## 外部输入

OV13855 只是本次迁移时使用的可替换验收示例，不是 RKISP 服务的固定依赖。IQ 与
sensor module、镜头及 ISP 版本绑定，仓库基础配置不定义 IQ 文件、安装名或数据包。
产品定制应在自己的提交中加入匹配的 overlay、IQ 包和安装配置，不能把其他 sensor
的 JSON 改名后当成量产 IQ。

`prepare-local-debs.sh` 只汇集 RKAIQ/RKISP 的 SDK 软件包；构建 rootfs 时
`install-local-debs.sh` 安装服务、重启策略和目标 QA。板级 IQ 由定制提交独立接入。

## 可替换的 OV13855 示例

`config/dts/examples/rk3576-ov13855-camera.dtso` 描述 MYD-LR3576 CAM3 的 I2C8、
四 lane CSI2 DPHY3、rkcif、rkisp 和 rkvpss 链路，并覆盖基础 DTB 中占用同一接口的
Jaguar 节点。示例位于子目录，不会被默认 overlay 自动发现；产品定制需把选定的
`.dtso` 放入配置的 `DTS_OVERLAY_DIR`，与默认 disable-DSI overlay 一起构建。

若当前 U-Boot 版本未能应用多个 FDTOVERLAYS，可用同一组输入离线合并后验证，不能仅
根据 extlinux 文本判断 overlay 生效：

```bash
dtc -@ -I dts -O dtb -o /tmp/disable-dsi.dtbo config/dts/rk3576-disable-dsi.dtso
dtc -@ -I dts -O dtb -o /tmp/camera.dtbo config/dts/examples/rk3576-ov13855-camera.dtso
fdtoverlay -i /boot/dtb/board.dtb -o /tmp/board-with-camera.dtb \
  /tmp/disable-dsi.dtbo /tmp/camera.dtbo
```

## 实机 QA

### JR3576 的 CSI1 OV13855

JR3576 当前基础设备树 `kernel-6.1/arch/arm64/boot/dts/rockchip/myd-jr3576.dts`
包含 `myd-jr3576-csi1-ov13855.dtsi`。该链路使用 I2C3 地址 0x36、四条
MIPI lane、`csi2_dcphy0`、`rkcif_mipi_lvds`、`rkisp_vir0` 和 `rkvpss_vir0`。
它与上面的 MYD-LR3576 CAM3 示例不是同一接口；JR3576 无需启用该示例 overlay。
刷机后先核对 `/proc/device-tree/model`、传感器 subdev 名称、`media-ctl -p`
拓扑和 `journalctl -b -k` 中的 OV13855 probe，再运行下面的实际取帧验收。
只有 probe 成功、3A 无 AE/AWB 错误且真实镜头画面 30 帧通过，才标记 ISP 通过。
SDK 附带的 OV13855 IQ 文件是否匹配新接入的模组仍需单独确认；不能只因文件名
包含 OV13855 就视为匹配。

镜头保持无遮挡、禁用 sensor test pattern 后运行：

```bash
sudo /usr/libexec/ubuntu-isp-camera-qa
```

当前示例的通过条件是实体 OV13855 subdev 存在、rkisp mainpath 可用、rkaiq 日志出现
`rkisp_init engine succeed`，并实际取得 30 帧 NV12，文件大小、DQBUF 序号和像素
变化均满足要求。成功输出 `RKAIQ_OK`、`RKISP_FRAME_OK` 和 `ISP_CAMERA_OK`。

2026-09-03 的 MYD-LR3576 实测中，sensor ID `OV00d855`、4224×3136@30 输入和
640×480 NV12 30 帧抓取均成功，文件为 13,824,000 字节。SDK 现有
`isp3x/ov13855_CMK-OT2016-FV1_default.json` 能被加载并启动 rkisp，但 rkaiq
v6.30.4/ISP39 报 AE/AWB schema 不兼容；它只能作为 bring-up 输入，不能标记为量产
IQ。替换 sensor 时应由定制提交提供相应 overlay、IQ 和 QA sensor 匹配条件；量产
前必须使用匹配模组的调校文件重新执行上述 QA 和画质验收。

`rkaiq_3A.service` 保持启用，但启动前由 `rockchip-rkaiq-ready` 从 V4L2 sensor subdev
名称解析 sensor，并确认 `/etc/iqfiles` 中存在同名前缀 IQ。没有启用摄像头 overlay
或没有匹配 IQ 时，systemd 以 ExecCondition 未满足干净跳过，不会反复启动并崩溃。

## JR3576 Server 单摄像头服务验收（2026-10-10）

JR3576 CSI1 的 OV13855 已在 I2C3 0x36 读出芯片 ID `OV00d855`。
`rk3576-disable-dsi.dtso` 保留共享 mipidcphy0 的基础状态，避免关闭 CSI PHY。
使用 `config/dts/examples/rk3576-jr3576-ov13855-only.dtso` 禁用未接入的
CSI0/CSI2 OV5640 及其虚拟 ISP/VPSS 管线，避免 RKAIQ 初始化 FakeCamera。
把该示例与 disable-DSI 一起放入本次 `DTS_OVERLAY_DIR`，不会默认启用示例。

本次用户要求验证 3A 服务启动，暂不评价图像质量。旧 ISP3x OV13855 IQ
缺少 ISP39 的算法参数，不能直接作为服务验收输入。
`package/isp/prepare-isp39-bringup-iq.py` 将 SDK ISP39 默认参数与真实 OV13855
增益/曝光寄存器换算、限值、延迟及模组元数据组合；生成文件及输入摘要保留在
本次输出目录，经 `CAMERA_IQ_DIR` 安装为 `ov13855_default_default.json`。
该文件只用于服务 bring-up，未验证画质、HDR 或量产调校。

在 SDK 根目录生成（输出目录不得纳入 Git）：

```bash
uv run python ubuntu/package/isp/prepare-isp39-bringup-iq.py \
  external/camera_engine_rkaiq/rkaiq/iqfiles/isp3x/ov13855_CMK-OT2016-FV1_default.json \
  external/camera_engine_rkaiq/rkaiq/tools/iqUpdateRule/RK3576/awb_isp39_default.json \
  output/ubuntu-server-jr-20261010/camera-iq/ov13855_default_default.json
```

输入与输出 SHA256 写入 `.json.provenance` 旁文件，避免被 IQ staging 的
`*.json` 规则当成摄像头参数安装。

供应的 RKAIQ 6.30.4 二进制使用旧版两缓冲区网格 ioctl；Linux 6.1 使用三缓冲区
结构，旧请求返回 ENOTTY 后触发 CAC 空指针。兼容补丁与应用说明位于
`docs/patches/kernel/`，保留新接口并单独支持旧请求。

服务验收使用 `tests/target/test-isp-3a-service.sh`：确认实体 subdev、服务启用、
RKAIQ init/prepare、IQ 加载及 30 秒内进程不退出或重启；线程创建失败也会失败。
另行实际采集 NV12 帧，检查实时统计线程与服务 PID 稳定性。该范围不包含
要求真实光学像素变化、匹配调校及画质的 `test-isp-camera.sh` 完整验收。

Server 内核片段禁用 `CONFIG_RT_GROUP_SCHED`，使 cgroup v2 下 RKAIQ 的
实时统计线程可运行（本 SDK 为 SCHED_RR，优先级 20）。最终板端结果和镜像
摘要见 `docs/QA-SERVER-JR3576-20261010.md`。
