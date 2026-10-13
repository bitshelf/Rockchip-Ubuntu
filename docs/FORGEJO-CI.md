# Forgejo CI 推送与 Ubuntu Server 编译

本文档说明如何在 ARM64 构建主机完成 Forgejo 验收、配置 Git
HTTP 访问、推送分支，以及触发 native ARM64 Ubuntu Server
CI 编译。构建主机的完整搭建原理见
[ARM64-BUILD-HOST.md](ARM64-BUILD-HOST.md)。

## 构建主机配置

如果根文件系统是 OverlayFS，容器存储必须使用真实文件系统。
以 209 为例，它的真实 ext4 后端挂载在 `/userdata`，因此在本机
`.env` 中配置 `BUILD_STORAGE_ROOT="/userdata"`。这是主机环境配置，
不是仓库固定路径。

```bash
cd ~/ubuntu
cp -n .env.example .env
```

在 `.env` 中设置：

```bash
BUILD_STORAGE_ROOT="/userdata"
BUILD_OUTPUT_DIR="/var/lib/ubuntu-ci/build"
FORGEJO_PUBLIC_HOST="192.168.1.209"
```

完成搭建并执行运行时验收：

```bash
sudo ./scripts/setup-build-host.sh
sudo ./scripts/setup-build-host.sh --check
```

如果第一条命令被中断，必须重新执行并等待脚本完成，不能仅根据
已创建的 Docker 目录判定 Forgejo 和 Runner 已经可用。

## 提交前构建与 CI 复验

Forgejo 只能构建已提交并推送的源码，不能看到开发目录中的未提交修改。
开发时先在 ARM64 主机对当前工作区执行手工构建和最小 QA，审核后再
创建功能提交并 push，由 CI 对该提交做第二次验证。

rootfs 工作流只响应分支 push 和手动触发；附件发布与候选版本的 tag
不重复启动整套 rootfs 构建。Forgejo 与 GitHub 使用相同规则。

```text
修改 -> ARM64 手工构建 -> 最小 QA -> 审核 -> commit -> push -> Forgejo CI
```

## 配置 Forgejo SSH 公钥

搭建脚本会创建 `ubuntu/ubuntu` 私有仓库。先在要执行 push 的开发
账户下查看 SSH 公钥：

```bash
cat ~/.ssh/id_ed25519.pub
```

如果尚未创建该密钥，执行：

```bash
ssh-keygen -t ed25519
```

在浏览器打开 `http://192.168.1.xxx:3000`，使用以下凭据文件中的
管理员账号登录：

```bash
sudo cat /etc/ubuntu-ci/forgejo-admin.env
```

进入“用户设置 -> SSH/GPG 密钥 -> 添加 SSH 密钥”，添加前面的公钥。
管理员密码不得写入 Git remote URL、脚本或已跟踪文件。

## 添加远程仓库并推送

在 Ubuntu 开发仓库中添加 Forgejo remote：

```bash
cd /path/to/ubuntu
git remote add forgejo \
  ssh://git@192.168.1.209:2222/ubuntu/ubuntu.git
git remote -v
git push -u forgejo ubuntu26
```

如果 `forgejo` remote 已存在，只更新它的地址：

```bash
git remote set-url forgejo \
  ssh://git@192.168.1.209:2222/ubuntu/ubuntu.git
git push -u forgejo ubuntu26
```

首次连接 2222 端口时需要核对并接受 Forgejo 容器的 SSH 主机密钥。
浏览器和 Git HTTP clone 使用 3000 端口；Forgejo 内置 Git SSH 使用 2222
端口；目标板系统 SSH 使用 22 端口，三者不要混用。
如果目标板恢复出厂后 22 端口的 SSH 主机密钥发生变化，应先在目标板
本地核对新指纹，不应直接禁用主机密钥检查。

## Forgejo workflow

仅执行 `git push` 不会自动编译。仓库必须包含
`.forgejo/workflows/server.yaml`，Forgejo 才能把 push 交给
`native-arm64` host runner。workflow 不绑定 Ubuntu 系列或开发分支，发行版
升级时继续使用同一入口。最小流程为：

```yaml
name: Ubuntu Server

on:
  push:
  workflow_dispatch:

jobs:
  build-server:
    runs-on: native-arm64
    timeout-minutes: 720

    steps:
      - name: Checkout
        uses: https://data.forgejo.org/actions/checkout@v4

      - name: Source checks
        run: ./scripts/check-source.sh

      - name: Check build environment
        run: ./build.sh server --check

      - name: Check SDK platform assets
        run: ./scripts/stage-sdk-assets.sh --check

      - name: Build server rootfs
        run: ./build.sh server
```

Forgejo 的原生 workflow 目录是 `.forgejo/workflows`；GitHub 对应文件位于
`.github/workflows`。Runner 从 systemd 服务继承 `BUILD_OUTPUT_DIR`，因此 CI 与
ARM64 手工构建仍可共用 `/var/lib/ubuntu-ci/build`。

SDK 的 kernel/DTB/modules/DEB 输入按 [SDK-ASSETS.md](SDK-ASSETS.md) 暂存；
workflow 可以复用同一目录，也可以下载 Forgejo/GitHub Release。二进制不提交到
Git，双 CI 配置见 [CI-ASSETS.md](CI-ASSETS.md)。

## 查看 CI 状态与下载 rootfs

通过 Forgejo 页面的 `ubuntu/ubuntu -> Actions` 查看任务日志，或在 209
上查看 Runner 状态：

```bash
sudo systemctl status forgejo-runner --no-pager
sudo journalctl -u forgejo-runner -f
```

CI 构建产出保存在：

```text
/var/lib/ubuntu-ci/build
```

构建通过后，打开对应 workflow run，在页面的 Artifacts 区域下载
`ubuntu-*-server-arm64-<run-id>`。其中包含 rootfs、SHA256、manifest、filelist、
build-info 和 QA JSON。上传前会重新验证 rootfs SHA256；由于 rootfs 已经压缩，
artifact action 禁用二次压缩以减少 ARM64 CPU 和上传等待时间。保留期限使用
Forgejo 实例策略，不在仓库中写死。

编译成功后检查 Server rootfs、manifest、filelist 和 SHA256 文件：

```bash
find /var/lib/ubuntu-ci/build/images -maxdepth 1 -type f -printf '%f\n' | sort
find /var/lib/ubuntu-ci/build/images -maxdepth 1 -name '*.sha256' \
  -execdir sha256sum -c '{}' \;
```

如果 Forgejo 页面一直显示等待 Runner，检查 Runner 是否已注册并且
`native-arm64` 标签在线：

```bash
sudo ./scripts/setup-build-host.sh --check
sudo journalctl -u forgejo-runner -n 200 --no-pager
```

host runner 直接在构建主机执行 action。`checkout` 是 JavaScript action，
因此主机必须从 Debian/Ubuntu 软件源安装与所选 action 兼容的 `node`，不引入
第三方 Node 软件源。`setup-build-host.sh --check` 会以实际 CI 账户执行
`node --version`，避免任务到 checkout 阶段才发现运行时不可用。升级 action
前必须先在目标 Runner 上验证其 Node.js 运行时要求。
