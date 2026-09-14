# Chromium ARM64 当前稳定源码交叉编译与 DEB 打包

Chromium 构建使用上游 GN/Clang 双工具链在 x86_64 上构建 ARM64 payload，
再生成可安装的 Chromium ARM64 DEB。RK3576 的 Wayland/V4L2 适配通过 GN 参数和
源码补丁进入同一构建，避免把未匹配版本的官方运行时拼入镜像。


## 外部输入

以下输入体积很大或属于上游二进制，均不进入 Git：

| 变量 | 要求 |
| --- | --- |
| `CHROMIUM_SOURCE_DIR` | 完整 Chromium checkout 的 `src` 绝对路径 |
| `CHROMIUM_DEPOT_TOOLS_DIR` | `depot_tools` 绝对路径 |
| `CHROMIUM_VERSION` | source checkout 对应的完整版本 |

源码按 Chromium 官方流程用 `fetch chromium`/`gclient sync` 准备，并切到当前
Linux stable 版本。只有当前版本已评审的 RK3576 补丁目录才可通过
`CHROMIUM_PATCH_DIR` 显式传入；默认不复用旧版补丁。

## 构建与打包

在 `.env` 填写上述变量和 `CROSS_BASE_TAG` 后运行：

```bash
./scripts/build-cross-example.sh chromium
```

容器会调用 Chromium checkout 自带的依赖安装脚本、ARM64 sysroot 安装脚本和
`gclient runhooks`，随后执行 `gn gen` 与 `autoninja`。默认 GN 参数位于
`package/chromium/args.gn`；只对当前源码版本有效的附加参数可通过
`CHROMIUM_EXTRA_GN_ARGS` 提供，并应在正式移植时固化为对应功能的可评审配置。

## 产物与最小 QA

```text
build/cross/packages/chromium/
├── chromium_<version>_arm64.deb
├── build-info
└── SHA256SUMS
```

构建阶段和打包阶段都会检查 Chromium payload 中的 ELF 为 `AArch64`。成功标志：

```text
CHROMIUM_ARM64_PAYLOAD_OK
CHROMIUM_ARM64_DEB_OK
```

目标板安装与启动验收应至少包含：

```bash
sudo apt install ./chromium_<version>_arm64.deb
chromium --version
```

## 源码归属与版本边界

构建会核对 `chrome/VERSION` 与 `CHROMIUM_VERSION`。显式补丁目录中的补丁按
series 顺序应用；不匹配时失败，不能跳过失败补丁继续打包。外部源码和生成的
DEB 不进入 Git；Ubuntu GNOME 发布镜像默认采用 Canonical ARM64
`latest/stable` Snap，交叉构建入口用于稳定渠道缺少 RK3576 功能时的当前版本移植。

`tests/host/test-chromium-deb.sh` 使用小型 ARM64 ELF 验证 DEB 布局及错误架构
拒绝行为，不代表 Chromium 已完整编译。真实产物仍须记录源码 revision、补丁
series、GN 参数、构建日志与包 SHA256，并在目标普通用户会话中验证沙箱、
Wayland 页面显示及视频解码。没有完整源码构建及板端结果时，验收保持待完成。
