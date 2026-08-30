# ARM64 构建与 Forgejo 主机搭建

ARM64 主机同时承担 Ubuntu 代码开发、rootfs 原生构建和 Forgejo 服务。主机可以
运行 Debian 或 Ubuntu，但必须是非容器化的完整系统。x86 主机负责依赖 Rockchip
SDK 的二进制编译和最终固件打包。

## 前提

- `/dev/loop-control` 可用；
- 内核启用并挂载 AppArmor securityfs；
- Docker 数据目录位于真实文件系统；
- Node.js 可用，用于在 host runner 上执行 Forgejo JavaScript actions；
- 能访问 Debian/Ubuntu 软件源、Snap Store、Forgejo 镜像和 Runner 下载地址；
- TCP 3000 和 2222 可供 Forgejo HTTP 与 Git SSH 使用。

APT 软件源默认优先使用清华源，并在新主机上按清华、阿里云、腾讯云顺序探测。
已有且可访问的这三类国内源会原样保留。Ubuntu ARM64 使用 `ubuntu-ports`，
Ubuntu x86 使用 `ubuntu`，Debian 使用 `debian`；内网也可以通过 `APT_MIRROR`
明确指定镜像地址。代理变量不是构建环境的默认配置。

如果产品内核不能从 squashfs 暴露 `snap-confine` 文件能力，脚本会在标准目录
`/var/lib/ubuntu-ci` 保存带 capabilities 的副本，通过开机服务绑定到 snapd
路径，并暂停 snap 自动刷新，避免刷新后 `ubuntu-image` 再次失效。脚本不绑定
任何特定分区名或挂载点。`--check` 会实际执行
`ubuntu-image --version`，不会只检查 snap 是否安装。

如果主机根文件系统是 OverlayFS，必须另外提供适合保存容器层的真实文件系统。
脚本将后端存储 bind mount 到标准的 `/var/lib/docker` 与
`/var/lib/containerd`，Docker/containerd 配置不依赖后端分区名称：

```bash
sudo BUILD_STORAGE_ROOT=/path/to/storage ./setup-build-host.sh
```

- 如果没指定`BUILD_STORAGE_ROOT`，可能会报错 `ERROR: BUILD_STORAGE_ROOT must name a real filesystem when / is OverlayFS` 的错误

也可以在 .env 指定
```
BUILD_STORAGE_ROOT="/userdata"
BUILD_OUTPUT_DIR="/var/lib/ubuntu-ci/build"
```

## 手动搭建

`setup-build-host.sh` 是独立可执行文件，可以单独拷贝到 ARM64 主机：

```bash
scp scripts/setup-build-host.sh <arm64-host>:/tmp/
ssh <arm64-host>
chmod +x /tmp/setup-build-host.sh
sudo FORGEJO_PUBLIC_HOST=<arm64-host-ip> /tmp/setup-build-host.sh
```

ARM64 默认使用 `/var/lib/ubuntu-ci/build`。也可以在 `.env` 中指定其他绝对路径：

```bash
BUILD_OUTPUT_DIR=/path/to/shared-build
```

脚本会把该目录及 `work/cache/images/packages/platform-assets/releases` 一级目录
配置为 `ubuntu-build` 组可写的 setgid 目录，将 `ubuntu-ci` 和执行
搭建的开发账户加入该组，并把同一路径注入 Forgejo Runner。开发账户首次加入组后
需要重新登录。这样手动 native 构建与 CI checkout 即使位于不同目录，也不会产生
两套互相看不到的构建产物。

在 x86 主机上运行时，默认使用仓库中的 `build/`，同时安装
`qemu-user-static` 和 `binfmt-support`，保留 x86 `ubuntu-image` 构建路径。

脚本一次完成：

1. 安装 rootfs 构建依赖、Node.js、Docker、apt-cacher-ng 和 snapd；
2. 安装 Canonical `ubuntu-image` classic snap；
3. 启动 Forgejo，创建私有 `ubuntu` 仓库；
4. 创建专用 `ubuntu-ci` Runner 账户并注册单并发 host runner，Runner 启动前
   等待 Forgejo health 就绪，避免主机重启时产生瞬时失败；
5. 准备手动 native 构建与 CI 共用的产出目录；
6. 执行与 `--check` 相同的运行时验收。

登录主机的开发账户不参与脚本配置。Forgejo Runner 固定使用脚本创建的专用账户，
其免密 sudo 仅用于可信私有仓库中的 loop、mount 和 chroot 构建任务。

Forgejo 数据保存在 `/var/lib/forgejo`，Compose 配置保存在
`/etc/ubuntu-ci/forgejo-compose.yaml`，管理员凭据保存在
`/etc/ubuntu-ci/forgejo-admin.env` 且仅 root 可读。脚本成功后会输出 Forgejo Web
和 Git SSH 地址。

## 开发与同步

在 ARM64 主机克隆 Forgejo 仓库，并把它作为 Ubuntu 的手动开发目录：

```bash
git clone ssh://git@<arm64-host>:2222/ubuntu/ubuntu.git
cd ubuntu
```

x86 主机完成 KO、DT overlay 等板级二进制编译后，将它们和 SHA256 清单同步到
ARM64 开发目录。

开发顺序固定为：

```text
x86 构建板级二进制 -> 同步到 ARM64 -> 构建 rootfs -> QA -> git commit/push
```

rootfs 生成后，再同步回 x86 SDK 主机合成可烧录镜像。

## 验收

源码级自检不需要 root：

```bash
./scripts/setup-build-host.sh --self-test
```

搭建后执行只读运行时检查：

```bash
sudo ./scripts/setup-build-host.sh --check
```

检查覆盖 AppArmor、loop、apt-cacher-ng、Docker、`ubuntu-image`、Forgejo、Runner
共享构建产出目录，以及 x86 主机上的 ARM64 QEMU 入口。任一前提不满足都会
非零退出。

## 网络代理

可以复制 `.env.example` 为不提交的 `.env`，也可以直接传入环境变量：

```bash
sudo HTTP_PROXY=http://proxy.example.com:3128 \
  HTTPS_PROXY=http://proxy.example.com:3128 \
  NO_PROXY=127.0.0.1,localhost,::1 \
  FORGEJO_PUBLIC_HOST=<arm64-host-ip> \
  ./scripts/setup-build-host.sh
```

apt-cacher-ng 仅监听 `127.0.0.1:3142`。
