# Ubuntu Desktop DRM cursor 验收

RK3576 的桌面 cursor 由 DRM cursor plane 和 Mutter/Wayland 会话共同决定。`modetest -p` 只能证明内核导出了 cursor plane，不能替代 GNOME Shell 中的可见、移动和热插拔验收。使用与 Resolute 匹配的 libdrm。旧 `libdrm-cursor` 组件是否需要接入 Mutter，须根据源码和实机行为判断，不能仅因旧镜像安装过便默认注入 GNOME。Server 不安装桌面 cursor 组件。

先在目标正常 rootfs 中执行能力检查：

```sh
tests/target/test-drm-cursor.sh
```

进入 GNOME Wayland 会话后，再执行桌面检查：

```sh
DRM_CURSOR_DESKTOP=1 tests/target/test-drm-cursor.sh
```

随后人工移动指针经过主屏、HDMI/DP 输出，改变光标大小，锁屏/解锁并热插拔一次显示器。记录 `modetest -p/-c`、`gnome-shell --version`、`journalctl -b -u gdm3` 和 Mutter 日志；确认没有 `DRM_IOCTL_MODE_CURSOR`、atomic commit 或 plane 格式错误。失败时应先保留软件 cursor 作为回退，不能通过关闭 Wayland 或强制 Xorg 掩盖硬件 cursor 问题。

## 判定边界

`modetest` 每个 plane 的 type 枚举都包含 `Cursor=2`；只有实际 `value: 2`
才表示该 plane 是 cursor。`disconnected` 也不能被当作 `connected`。
能力门禁通过仍不证明 Mutter 正在扫描输出硬件光标，必须在实际 GNOME 会话中
结合 DRM state、指针移动、光标大小变化、锁屏和显示器热插拔记录验收。
当前移植与实机验收尚未完成；按本轮 `artifacts/` 中证据记录进度，不沿用旧日期
的 recovery 设备枚举作为通过结果。

## RK3576 HDMI/DP 配置

`config/dts/optional/rk3576-desktop-cursor.dtso` 给 VP0 分配 Esmart2（物理 ID 8），
给 VP1 分配 Esmart3（物理 ID 9）作 cursor，保留 Esmart0/1 主平面。
此配置针对 DSI 已关闭的 HDMI/DP 桌面，不能与使用这些窗口的 VP2/DSI 配置混用。
内核 VOP2 驱动已有 `cursor-win-id` 支持，不需要全局替换 libdrm 或注入预加载库。

先在 x86 主机编译 overlay：

```sh
dtc -@ -I dts -O dtb -o rk3576-desktop-cursor.dtbo config/dts/optional/rk3576-desktop-cursor.dtso
```

在单独目录中放入所需的 disable-dsi、相机及 cursor overlay，并将其绝对路径
传给 `DTS_OVERLAY_DIR` 构建 bootfs。该接口只启用目录顶层文件，因此可选 cursor
源码不会自动进入 Server。extlinux 的 `fdtoverlays` 应同时保留 disable-dsi 和
原有相机 overlay。回滚时从该列表移除
`rk3576-desktop-cursor.dtbo` 并重启即可，不改变 rootfs 账户配置。

当前发行版 modetest 使用 DRM bus ID；脚本默认 `DRM_BUSID=display-subsystem`，
明确指定 `-M rockchip -D display-subsystem`，不能将 `/dev/dri/card0` 当作 bus ID。

已在 RK3576 / Ubuntu 26 GNOME Wayland 用户会话中验证该 overlay 能注册两个
Cursor plane，并使 HDMI 的 Esmart2 使用 AR24 cursor framebuffer 随输入事件
更新坐标。此验证不覆盖未连接的 DP、显示器热插拔或肉眼显示检查；每次验收的
具体镜像、boot ID 和 DRM state 保存在 `artifacts/`。
