# 构建指南

## 构建模式一览

| 模式 | 触发方式 | 耗时 | 适用场景 |
|------|---------|------|---------|
| **远程 ARM64 原生** | `trigger-build.sh` → GitHub Actions → SSH 到 ARM64 目标 | ~30 min | 日常开发、CI/CD |
| **ARM64 本地原生** | SSH 到 ARM64 设备直接跑 `sudo bash build.sh` | ~30 min | 调试、开发 |
| **QEMU 交叉编译** | GitHub Actions `mode: cross` 或 `BUILD_MODE=cross` | ~90 min | 无 ARM64 设备时 |

> **架构自动检测**：`.env` 会自动检测当前架构决定 `BUILD_MODE`：
> - `x86_64` → `BUILD_MODE=remote`（通过 SSH 部署到 ARM64 开发板）
> - `aarch64/arm64` → `BUILD_MODE=local`（本地原生编译）
> - 可手动覆盖：`BUILD_MODE=cross bash build.sh`

---

## 自托管 ARM64 Runner（在 Debian 开发板上）

### 仓库结构

`ubuntu/` 作为**独立的 git 仓库**推送到 GitHub。ARM64 Runner 只 checkout 这个仓库，**不包含** kernel、u-boot、rkbin 等 SDK 大目录。

Runner checkout 后的路径（假设 repo 名为 `ubuntu-rk3576`）：

```
~/
├── actions-runner/              # GitHub Actions Runner
│   └── _work/
│       └── ubuntu-rk3576/       # 仓库名 (owner/repo 的 repo 部分)
│           └── ubuntu-rk3576/   # checkout 的工作目录
│               ├── build.sh
│               ├── .env
│               ├── scripts/
│               ├── boards/
│               ├── seeds/
│               └── ...
```

### 手动执行构建命令

SSH 到 ARM64 Runner 设备后：

```bash
# 1. SSH 登录
ssh linaro@192.168.1.231

# 2. 找到 checkout 的工作目录（仓库名可能在 .env 或 git remote 查看）
cd ~/actions-runner/_work/<repo>/<repo>/

# 例如：
cd ~/actions-runner/_work/ubuntu-rk3576/ubuntu-rk3576/

# 3. .env 会自动检测架构 → BUILD_MODE=local
#    直接运行即可（不需要手动 export 任何变量）
sudo bash build.sh rootfs-only

# 4. 查看构建结果
ls -lh artifacts/rootfs.tar.gz
tail -100 artifacts/ubuntu-image.log
```

### 查看源码

```bash
# 目录结构
ls
# build.sh  .env  scripts/  boards/  seeds/  artifacts/  ...

# 查看 board 配置
cat boards/rk3576/rk3576.conf

# 查看当前 checkout 的 commit
git log --oneline -5

# 查看 .env 配置
cat .env
````

### 手动触发 workflow（不经过 GitHub）

如果你只想在 ARM64 设备上跑一次构建而不用走 CI：

```bash
# 方法 1：直接跑 build.sh（最快）
cd /tmp/ubuntu-build
export BOARD=rk3576 SDK_PATH=/tmp/ubuntu-build BUILD_MODE=local SKIP_SDK_CHECKS=1
sudo bash build.sh

# 方法 2：用 deploy-to-debian.sh 从 x86 开发机推送代码并触发构建
# （在 x86 开发机上执行）
bash .github/scripts/deploy-to-debian.sh 192.168.1.231 desktop
```

### 调试失败的构建

```bash
# 1. 查看构建日志
less /tmp/ubuntu-build/artifacts/ubuntu-image.log

# 2. 进入 ubuntu-image 的 chroot 环境（如果构建失败在中途）
#    ubuntu-image 的 work 目录在 artifacts/work/
sudo ls artifacts/work/chroot/

# 3. 手动 chroot 进去检查
sudo chroot artifacts/work/chroot/ /bin/bash
# 在 chroot 里可以：
#   apt-get update
#   dpkg --configure -a
#   apt-get install -f

# 4. 清理并重试
sudo rm -rf artifacts/work/
sudo bash build.sh rootfs-only
```

### Runner 状态管理

```bash
# 查看 Runner 状态
cd /home/linaro/actions-runner
./svc.sh status

# 重启 Runner
./svc.sh restart

# 查看 Runner 日志
tail -f /home/linaro/actions-runner/_diag/*.log

# 临时停掉 Runner（不让它接新的 job）
./svc.sh stop
# 手动做完你要做的事...
./svc.sh start
```

### 安装自托管 Runner（首次设置）

```bash
# 1. 在 GitHub 仓库 Settings → Actions → Runners → New self-hosted runner
#    选择 Linux ARM64，按提示操作

# 2. 在 ARM64 设备上
mkdir -p ~/actions-runner && cd ~/actions-runner
curl -o actions-runner-linux-arm64.tar.gz -L \
  https://github.com/actions/runner/releases/download/v2.322.0/actions-runner-linux-arm64-2.322.0.tar.gz
tar xzf actions-runner-linux-arm64.tar.gz

# 3. 配置
./config.sh --url https://github.com/<owner>/<repo> --token <TOKEN> \
  --labels self-hosted,linux,arm64 --name myd-lr3576-debian

# 4. 安装为 systemd 服务
sudo ./svc.sh install linaro
sudo ./svc.sh start
```

---

## 前置条件

- `ubuntu-image` v3.x: `sudo snap install ubuntu-image --classic`
- `e2fsprogs`, `dosfstools`
- RK3576 SDK (用于内核/U-Boot/Rockchip 包的构建)

---

## 常见问题

### `core snap not found`（preseed_image 阶段）

不要用 `sudo snap install core` —— 这把 core snap 装到宿主机，但 ubuntu-image 的
`snap-preseed` 需要从 Snap Store 下载作为镜像构建流程的一部分。

在 `image-definition.yaml` 中加 `extra-snaps: [snapd]`，ubuntu-image 会自己下载 snapd + core 依赖：

```yaml
# CI workflow 里
sudo snap install core  # 无用！snap-preseed 不走这里

# image-definition.yaml 里 — 正确做法
extra-snaps:
  - name: snapd
```

### `debootstrap` 找不到 `noble` 版本（Debian 12）

```bash
# Debian 12 的 debootstrap 可能没有 noble 脚本
sudo ln -sf gutsy /usr/share/debootstrap/scripts/noble
```

### `/tmp` 挂载为 `noexec`

```bash
# ubuntu-image 需要 /tmp 可执行
sudo mount -o remount,exec /tmp
```

### `git` 没有配置用户信息

```bash
# germinate seed merge 需要 git commit
git config --global user.email "builder@localhost"
git config --global user.name "Image Builder"
```
