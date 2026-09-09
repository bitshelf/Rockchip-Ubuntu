# x86 交叉编译 ARM64 环境

## 目标

这套环境在 x86_64 主机上构建 ARM64 二进制：

- x86_64 主机使用 `aarch64-linux-gnu-*` 交叉工具链；
- Debian 和 Ubuntu 都可作为宿主机，宿主机只需提供 Docker；
- Ubuntu 目标版本、镜像地址和产出目录均由环境变量配置。

ARM64 原生构建不属于本脚本范围；ARM64 构建主机继续负责 rootfs 和 CI。

容器只提供通用 C/C++ 构建环境，不包含 SoC 名称、Ubuntu 发行代号或具体版本。
板级 SDK 输入仍按 [SDK-ASSETS.md](SDK-ASSETS.md) 管理。

## 配置

复制示例配置并至少填写基础镜像标签：

```bash
cp .env.example .env
sed -i 's/^CROSS_BASE_TAG=.*/CROSS_BASE_TAG="<ubuntu-base-tag>"/' .env
```

也可以只对单次命令传值；命令行环境变量优先于 `.env`：

```bash
CROSS_BASE_TAG="<ubuntu-base-tag>" ./scripts/cross-build-env.sh --print-config
```

主要变量：

| 变量 | 用途 |
| --- | --- |
| `CROSS_BASE_IMAGE` | Ubuntu OCI 基础镜像名称，也可指向内部镜像仓库 |
| `CROSS_BASE_TAG` | 目标 Ubuntu 用户态对应的镜像标签，必须显式设置 |
| `CROSS_ENV_IMAGE` | 本地构建环境镜像名；留空时自动生成 |
| `CROSS_OUTPUT_DIR` | 可写产出目录；默认是仓库的 `build/cross` |
| `NATIVE_APT_MIRROR` | x86 Ubuntu 软件源，默认清华镜像 |
| `TARGET_APT_MIRROR` | ARM64 Ubuntu Ports 软件源，默认清华镜像 |

阿里、腾讯或内部镜像可通过上述两个 mirror 变量替换，无需修改 Dockerfile。
干净的 Ubuntu 基础镜像可能尚未包含 CA 证书。容器会先通过同一镜像的 HTTP
入口安装 `ca-certificates`，APT archive key 会验证索引和软件包；随后立即切换
回配置的 HTTPS 地址安装工具链。

## 准备与验收

首次使用或修改基础版本后构建容器：

```bash
./scripts/cross-build-env.sh --prepare
```

最小验收会实际编译和链接 C 程序，并通过 ELF 头确认产物为 AArch64：

```bash
./scripts/cross-build-env.sh --check
```

成功标志为：

```text
CROSS_BUILD_ENV_OK
```

该检查不是 QEMU 模拟，也不会在 x86_64 主机上执行 ARM64 程序。

## 编译项目

仓库以只读方式挂载到 `/workspace`，产出目录以可写方式挂载到 `/out`。容器
使用当前宿主用户的 UID/GID 运行，避免生成 root 所有的构建产物。
进入交互环境：

```bash
./scripts/cross-build-env.sh --shell
```

或直接执行构建命令：

```bash
./scripts/cross-build-env.sh -- sh -c 'cmake -S /workspace/example -B /out/example && cmake --build /out/example'
```

容器自动导出 `CC`、`CXX`、`AR`、`STRIP`、`CROSS_COMPILE` 和
`PKG_CONFIG_LIBDIR`。

## 移植到其他 Ubuntu 版本

1. 将 `CROSS_BASE_TAG` 改为新版本对应的 Ubuntu OCI 标签；
2. 如构建网络不同，只修改镜像和 APT mirror 变量；
3. 执行 `--prepare` 生成独立的新环境镜像；
4. 在 x86_64 Debian/Ubuntu 主机执行 `--check`；
5. 再使用该环境构建目标软件并保存项目自身的 QA 结果。

APT suite 从容器的 `/etc/os-release` 动态读取，因此迁移版本时不需要修改
脚本中的发行代号。若新版本改变了包名或工具链 ABI，应作为独立功能修改并
重新执行交叉编译验收。
