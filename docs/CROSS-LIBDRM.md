# libdrm ARM64 交叉编译与打包示例

该示例在 x86_64 Debian/Ubuntu 宿主机中，从所选 Ubuntu 基础版本的软件源
获取 `libdrm` source package 和对应 Build-Depends，应用仓库审核过的补丁后交叉
构建发行版原生 `.deb`。补丁入口按上游 source package 工作，不绑定 Ubuntu 代号；
升级基础版本时会重新从该版本软件源取源码，并在构建前验证每个补丁能否应用。

当前补丁只包含两个可独立解释的修复：静态构建时跳过不适用的 nouveau tests，
以及让 `modetest` 只查询命令实际请求的 KMS 资源。旧仓库以下两个 `HACK` 未迁移：

- `drmOpen(NULL, NULL)` 默认写死 `rockchip`，会改变所有 libdrm 调用者的设备选择；
- 默认绕过 magic、busid、set/drop-master，会把内核拒绝伪装成成功。

调用者和 QA 必须显式使用 `modetest -M <driver>`，认证与 DRM master 仍以真实内核
返回值为准。

## 构建

先按 [CROSS-COMPILE.md](CROSS-COMPILE.md) 配置 `.env` 的
`CROSS_BASE_TAG`，然后执行：

```bash
./scripts/build-cross-example.sh libdrm
```

脚本会先准备通用交叉编译镜像，再创建只属于 libdrm 的构建依赖层。Ubuntu
版本改变后，重新设置 `CROSS_BASE_TAG` 即会使用新版本的软件源和打包规则。
构建依赖层显式预装 `zlib1g:arm64`，用于规避部分 APT 版本在解析跨架构
Build-Depends 传递依赖时不自动选择该包的问题。补丁包版本在发行版版本后追加
`package/libdrm/version-suffix`，避免与 Ubuntu archive 的同版本包无法区分。

## 产物与最小 QA

产物位于：

```text
build/cross/packages/libdrm/
├── *.deb
├── build-info
└── SHA256SUMS
```

构建完成前会检查所有 `Architecture: arm64` 包中的 ELF，其 Machine 必须为
`AArch64`；`Architecture: all` 包单独保留。`build-info` 同时记录上游源码版本、
实际包版本和已应用 patch series。成功标志为：

```text
CROSS_DEB_EXAMPLE_OK=libdrm
```

安装前可再次校验：

```bash
cd build/cross/packages/libdrm
sha256sum -c SHA256SUMS
dpkg-deb -f ./*.deb Package Version Architecture
```

## 目标板功能 QA

安装同一次构建产生的 `libdrm-common`、`libdrm2` 和 `libdrm-tests` 后，明确指定
目标 DRM driver 执行只读检查：

```bash
sudo modetest -M <driver> -c
sudo modetest -M <driver> -p
```

两条命令都必须成功，connector/CRTC/plane 信息应与 `/sys/class/drm/` 一致，内核
日志不得新增 DRM error。不要用不带 `-M` 的结果验证板级选择，也不要通过环境变量
绕过 DRM auth/master 错误。运行桌面 compositor 前还应确认发行版包和本地包没有
混装：

```bash
dpkg-query -W -f='${Package} ${Version}\n' libdrm-common libdrm2 libdrm-tests
```
