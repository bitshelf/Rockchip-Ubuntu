# Chromium ARM64 当前稳定源码交叉编译与 DEB 打包

Chromium 构建使用上游 GN/Clang 双工具链在 x86_64 上构建 ARM64 payload，
再生成可安装的 Chromium ARM64 DEB。RK3576 的 Wayland/V4L2 适配通过 GN 参数和
源码补丁进入同一构建，避免把未匹配版本的官方运行时拼入镜像。


## 外部输入

以下输入体积很大或属于上游二进制，均不进入 Git：

| 变量 | 要求 |
| --- | --- |
| `CHROMIUM_SOURCE_DIR` | 完整 Chromium checkout 或官方归档展开后的 `src` 绝对路径 |
| `CHROMIUM_DEPOT_TOOLS_DIR` | `depot_tools` 绝对路径 |
| `CHROMIUM_VERSION` | source checkout 对应的完整版本 |
| `CHROMIUM_SOURCE_KIND` | `checkout`（默认）或 `archive` |

源码按 Chromium 官方流程用 `fetch chromium`/`gclient sync` 准备，并切到当前
Linux stable 版本。也可使用 Google 官方 release archive，记录 URL 与归档 SHA256
到 `src/.source-info`，并设置 `CHROMIUM_SOURCE_KIND=archive`。
默认应用仓库的 `docs/patches/chromium/series`；版本不匹配则停止。
可通过 `CHROMIUM_PATCH_DIR` 指定容器内可访问的另一补丁目录。

## 构建与打包

在 `.env` 填写上述变量和 `CROSS_BASE_TAG` 后运行：

```bash
./scripts/build-local-debs.sh chromium
```

对同一完整源码完成增量 GN/Ninja 编译后，将浏览器和对应资源暂存到
`CROSS_OUTPUT_DIR/chromium/payload/`，更新 `chromium/build-info` 中的源码、
GN 参数与补丁摘要。可通过同一入口只执行 ARM64 ELF 校验与 DEB 打包：

```bash
CHROMIUM_VERSION=155.0.8059.39 CROSS_OUTPUT_DIR=/absolute/cross-output \
  ./scripts/build-local-debs.sh chromium --package-only
```

此选项不会编译源码，必须保留已完成的实际编译、链接日志与产物校验值。
增量构建应使用原构建的 Ninja 版本，避免日志格式不兼容导致缓存失效。

容器会调用 Chromium checkout 自带的依赖安装脚本、ARM64 sysroot 安装脚本和
`gclient runhooks`（checkout）；归档模式只更新该版本指定的 Clang/Rust 工具链，
避免将归档变成不同的 Git checkout。随后执行 `gn gen` 与 `ninja`。默认 GN 参数位于
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
DEB 不进入 Git；Ubuntu GNOME 镜像通过本地 DEB manifest 安装 RK3576 浏览器，
不再预置缺少该设备适配的 Canonical Chromium Snap。入口将包及校验清单复制到
`SDK_OUTPUT_DIR/chromium`，由平台资源接口继续校验、组装。

`tests/host/test-chromium-deb.sh` 使用小型 ARM64 ELF 验证 DEB 布局及错误架构
拒绝行为，不代表 Chromium 已完整编译。真实产物仍须记录源码 revision、补丁
series、GN 参数、构建日志与包 SHA256，并在目标普通用户会话中验证沙箱、
Wayland 页面显示及视频解码。没有完整源码构建及板端结果时，验收保持待完成。
