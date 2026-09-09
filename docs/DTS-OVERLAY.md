# DTS overlay 编译与安装

## 简单约定

`scripts/build-bootfs.sh` 直接扫描 `config/dts/`：

- `.dtso` 使用 `dtc -@` 编译，同名安装为 `.dtbo`；
- `.dtbo` 原样安装；
- platform-assets 中 SDK 已生成的 `.dtbo` 同样安装，但不默认启用；
- `DTS_OVERLAY_DIR` 中的文件全部按排序结果写入 extlinux `FDTOVERLAYS`。

不再维护 `源文件|目标文件|enabled` 三字段清单或具体文件名数组。移植和定制只需
选择目录；目录可以是仓库的 `config/dts/`，也可以是 `build/` 下的外部输入目录。

当前仓库选择目录中提供 disable-DSI overlay，因此默认关闭板载 DSI route、
controller、panel、触摸、背光、PWM 和共享 DPHY，保留 HDMI/DP。移植其他 SoC 时
替换目录中的板级源文件即可，不需要修改 bootfs 配置或测试脚本。

## 构建

板型基础 DTB 由 `.env` 指定：

```bash
BOOTFS_BASE_DTB=myd-lr3576.dtb
```

然后构建独立 bootfs：

```bash
./build.sh bootfs
./build.sh bootfs --check
```

构建过程会校验源码可编译、DTBO 可解析、启用项确实存在，并用当前基础 DTB 做离线
合并。运行时合并使用 U-Boot 上游 FDTOVERLAYS 能力，不额外维护复杂的重启测试脚本。

## 手工安装

bootfs 在 Linux 中挂载为可写 `/boot`。安装前先离线检查：

```bash
fdtoverlay -i /boot/dtb/board.dtb -o /tmp/merged.dtb ./custom.dtbo
sudo install -m 0644 ./custom.dtbo /boot/overlays/custom.dtbo
sudoedit /boot/extlinux/extlinux.conf
sync
sudo reboot
```

在 extlinux 中加入：

```text
FDTOVERLAYS /overlays/board-policy.dtbo /overlays/custom.dtbo
```

后面的 overlay 可以覆盖前面的属性。基础 DTB 和 DTBO 必须带符号信息并来自兼容的
kernel binding。目标验收只检查启动日志和对应设备功能，不维护额外的重启测试脚本。
