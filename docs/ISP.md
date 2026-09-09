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
