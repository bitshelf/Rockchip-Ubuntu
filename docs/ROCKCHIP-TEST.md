# rockchip-test Debian 包与镜像 QA

Rockchip SDK 的 `external/rockchip-test/` 作为外部源码输入，不在 Ubuntu
仓库复制 9 MB 的脚本和 NPU model。构建脚本只在临时 package root 中把历史
`/rockchip-test`、`/data/rockchip-test` 和 `/userdata/rockchip-test` 转成标准目录：

- 程序：`/usr/lib/rockchip-test`；
- 入口：`/usr/bin/rockchip-test`；
- 测试状态与证据：`/var/lib/rockchip-test`。

## 构建

`.env` 可覆盖 `ROCKCHIP_TEST_SOURCE_DIR`；默认从
`$SDK_DIR/external/rockchip-test` 读取；源码目录中的 `.git` 不会进入 DEB：

```bash
./build.sh rockchip-test --check
./build.sh rockchip-test
```

deb 输出到 `$BUILD_OUTPUT_DIR/packages/rockchip-test/`，不会默认集成 rootfs。

## Server 与 Desktop

```bash
sudo dpkg -i rockchip-test_*_all.deb
sudo rockchip-test qa server
sudo rockchip-test qa desktop
```

Server profile 检查 headless 策略，不要求显示管理器、Chromium 或 WebGPU，但仍检查
DRM render、NPU、V4L2、音频和网络设备。Desktop profile 在相同硬件门禁上增加显示
管理器和 Chromium。两种 profile 都确认 adbd 与系统共享 network namespace。
JSON 证据写入 `/var/lib/rockchip-test/results/`。

`rockchip-test menu` 保留 vendor 交互菜单，其中 recovery、自动重启、掉电和压力项
会修改状态或长时间运行，必须由操作员在具备串口、恢复镜像和电源控制时明确启动；
自动 QA 从不调用这些项目。
