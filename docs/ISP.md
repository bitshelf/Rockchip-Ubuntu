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

摄像头接线、I2C 地址和 media graph 由所选板级设备树提供。先核对
`/proc/device-tree/model`、传感器 probe 和 `media-ctl -p`，显式选择实际 sensor。
未接入的 sensor/虚拟管线由板级配置禁用；不在公共仓库提交一次性板级 overlay。

`rkaiq_3A.service` 由 `rockchip-rkaiq-ready` 检查 sensor subdev 与同名前缀 IQ。
缺少摄像头或匹配 IQ 时，ExecCondition 跳过服务。服务启动验收使用
`tests/target/test-isp-3a-service.sh`，确认实体 subdev、IQ 加载、RKAIQ
init/prepare，以及观察窗口内进程不退出或重启。该结果不代表画质通过。
实际取帧与像素变化验收另用 `tests/target/test-isp-camera.sh`。

ISP39 bring-up IQ 可用 `package/isp/prepare-isp39-bringup-iq.py` 生成：

```bash
python3 package/isp/prepare-isp39-bringup-iq.py \
  /path/to/sensor-iq.json /path/to/isp39-default.json \
  /path/to/ignored-output/camera-iq/sensor_default_default.json
```

生成文件与 `.json.provenance` 保留在输出目录，通过 `CAMERA_IQ_DIR` 提供。
这只用于服务 bring-up，不能替代匹配模组的正式 IQ 调校。
RKAIQ 二进制与内核 mesh ioctl ABI 必须匹配，兼容补丁留在
`docs/patches/kernel/`。cgroup v2 下实时统计线程还需禁用
`CONFIG_RT_GROUP_SCHED`。所有运行记录与镜像摘要保留在 Git 忽略的输出目录。
