# Server rootfs 构建

## 移植

从 Ubuntu  官方 seed 构建 ARM64 Server rootfs。

构建使用 Canonical `ubuntu-image`。`.env` 中可把 `UBUNTU_PORTS_MIRROR` 切换为以下可靠国内源：

- `https://mirrors.aliyun.com/ubuntu-ports/`
- `https://mirrors.cloud.tencent.com/ubuntu-ports/`

Canonical seed 元数据仍从官方只读站点获取，并缓存到 `BUILD_OUTPUT_DIR`，
避免每次构建重复下载。

仓库的产品 seed 只列出 Server 必需包，并在 ubuntu-image 创建 chroot 后、
解析包依赖前安装 APT 策略，关闭 recommends/suggests 自动跟随。需要的可选包必须
在产品 seed 或 image definition 中显式选择。因此 `linux-firmware*`、
`unattended-upgrades`、`ubuntu-release-upgrader-core`、Thunderbird 和 LibreOffice
不会先安装再卸载；manifest 门禁会阻止这些包进入发布产物。

## 构建

先使用 `scripts/setup-build-host.sh` 准备非容器化 Debian/Ubuntu 主机，再执行：

```bash
./build.sh server --check
./build.sh server
```

ARM64 原生构建是手工开发首选。x86_64 主机通过 `qemu-user-static` 和
binfmt 保留相同入口，但 Ubuntu 20 构建 Ubuntu 26 时的稳定性不作为原生
ARM64 验收的替代品。

默认产出目录：

- ARM64：`/var/lib/ubuntu-ci/build/images/`
- x86_64：仓库的 `build/images/`

ARM64 手工构建和 Forgejo runner 必须在 `.env` 中使用相同的
`BUILD_OUTPUT_DIR`。脚本允许未提交工作区构建，因此可以按“修改、构建、审核、
提交”的顺序开发。
显式传给构建命令或 Runner 服务的环境变量优先于仓库 `.env`，便于 CI 和测试
隔离输出目录；未显式传入时才使用 `.env` 的主机配置。

## 产物与最小 QA

`images/` 中生成：

- `ubuntu-${UBUNTU_VERSION}-${VARIANT}-${ARCHITECTURE}.rootfs.tar.gz`
- `ubuntu-${UBUNTU_VERSION}-${VARIANT}-${ARCHITECTURE}.rootfs.tar.gz.sha256`
- `ubuntu-${UBUNTU_VERSION}-${VARIANT}-${ARCHITECTURE}.manifest`
- `ubuntu-${UBUNTU_VERSION}-${VARIANT}-${ARCHITECTURE}.filelist`
- `ubuntu-${UBUNTU_VERSION}-${VARIANT}-${ARCHITECTURE}.build-info`
- `ubuntu-${UBUNTU_VERSION}-${VARIANT}-${ARCHITECTURE}.qa.json`

构建结束前会解析 tarball，检查 `/usr/lib/os-release` 的 Ubuntu 发行版与系列、
dpkg 状态数据库、rootfs APT 镜像源、cloud-init 临时登录数据，以及 manifest
中的 `openssh-server`。这些检查只证明 rootfs 构建完整；启动、板级网络、内核
驱动和硬件功能必须由对应后续功能验收。

Server tarball 同时携带 `initramfs-tools` 和 `e2fsprogs`，供后续
`./build.sh overlay-root` 生成板级 initramfs；基础 tarball 本身仍不是 EROFS
或 OverlayFS 产物。

`qa.json` 记录本次 tarball 校验和与最小检查结果。

镜像通过 cloud-init 创建临时 `ubuntu` 账号，初始密码为 `ubuntu`，首次登录
必须修改。
