# Rockchip RK3576 Ubuntu 镜像构建

基于 `ubuntu-image`  为 Rockchip SOC 构建 Ubuntu 镜像。

## 快速开始

```bash
# 1. 配置
cp .env.example .env && vim .env

# 2. 构建
bash ubuntu/build.sh
```

## 配置 (.env)

所有构建参数集中在一个文件：

```bash
# ubuntu/.env — 构建配置
SOC_MODEL="rk3576"            # 目标 SOC
UBUNTU_SERIES="noble"          # 24.04 LTS
UBUNTU_VARIANT="desktop"       # server / desktop
BUILD_MODE="remote"            # remote(arm64 原生) / local(x86+qemu)
BUILD_HOST="192.168.1.183"     # remote 目标板 IP
BUILD_USER="root"
BUILD_DIR="/tmp/ubuntu-build"
PACKAGE_METHOD="mkupdate"      # mkupdate / gpt
```

也可以环境变量临时覆盖：

```bash
UBUNTU_VARIANT=server BUILD_MODE=local bash ubuntu/build.sh
```

## 目录结构

```
ubuntu/
├── .env                   # 构建配置 (gitignored)
├── .env.example            # 配置模板
├── build.sh → ubuntu-build-service/build.sh
├── ubuntu-build-service/                       # 构建脚本
│   ├── build.sh                                #   构建编排
│   ├── assemble-disk.sh                        #   GPT 磁盘镜像
│   ├── pack-updateimg.sh                       #   update.img 打包
│   ├── merge-overlays.sh                       #   overlay 合并
│   ├── build-remote.sh                         #   远程构建
│   ├── build-external-modules.sh               #   外部内核模块
│   ├── boot-assets/                            #   引导文件 (DTB, DTBO)
│   ├── seeds/                                  #   上游 germinate 种子
│   ├── seeds-local/                            #   本地种子覆盖 (blacklist 等)
│   ├── seeds-questing/                         #   Ubuntu 26.04 种子
│   └── ubuntu-overlay/                         #   [已废弃，迁移到 ../overlay/]
├── artifacts/                                  # 构建产物
│   ├── rootfs.tar.gz                           #   Ubuntu rootfs tarball
│   ├── update.img                              #   Rockchip 刷机镜像
│   ├── ubuntu-server-rk3576-arm64.img          #   GPT 磁盘镜像 (PACKAGE_METHOD=gpt)
│   └── ubuntu-image.log                        #   构建日志
├── boards/
│   ├── rk3576.conf                             #   板级配置 (主配置)
│   └── board-template.conf                     #   新板子模板
├── packages/
│   ├── kernel-debs/                            #   内核 .deb 包
│   ├── rockchip-debs/                          #   Rockchip 定制 .deb (MPP/RGA/Mali 等)
│   └── packages-patches/                       #   Rockchip 补丁
│       ├── libdrm/
│       ├── wayland/
│       ├── weston/
│       └── ...                                 #   每个包一个子目录
├── overlay/                                    # 本地 overlay 覆盖 (融合 SDK base)
│   ├── overlay/                                #   → debian/overlay/
│   ├── overlay-debug/                          #   → debian/overlay-debug/ (可选)
│   └── overlay-firmware/                       #   → debian/overlay-firmware/
├── scripts/                                    # 辅助脚本
│   ├── rebuild-rockchip-packages.sh
│   ├── docker-cross-build.sh
│   └── ...
└── tests/                                      # QEMU 测试套件
```

## 构建方式

### 打包方式选择

在 `boards/rk3576.conf` 中配置 `PACKAGE_METHOD`：

| 值 | 产物 | 工具 | 用途 |
|----|------|------|------|
| `mkupdate` (默认) | `update.img` | afptool + rkImageMaker | USB 刷机 (`upgrade_tool`) |
| `gpt` | `.img` (GPT 磁盘镜像) | sgdisk + dd | `dd` 写入 SD 卡 / eMMC |

### 环境变量

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `BOARD` | `rk3576` | 板级配置名 (对应 `boards/<BOARD>.conf`) |
| `SDK_PATH` | 自动推导 | Rockchip SDK 根目录 (从脚本位置自动检测) |
| `UBUNTU_SERIES` | `noble` | Ubuntu 系列 (noble / questing) |
| `OVERLAY_DEBUG_ENABLE` | `no` | 是否集成 debug overlay (开发用 yes，发版用 no) |

### 使用示例

```bash
# 默认构建 (update.img)
bash ubuntu/build.sh

# 构建 GPT 磁盘镜像
PACKAGE_METHOD=gpt bash ubuntu/build.sh

# 带调试工具
OVERLAY_DEBUG_ENABLE=yes bash ubuntu/build.sh

# 发版 (无调试 overlay)
OVERLAY_DEBUG_ENABLE=no bash ubuntu/build.sh

# 构建 Ubuntu 26.04 (questing)
UBUNTU_SERIES=questing bash ubuntu/build.sh
```

## 分区布局

| 分区 | 大小 | 标签 | 文件系统 | 用途 |
|------|------|------|----------|------|
| (raw LBA 64) | — | — | — | idbloader (SPL + DDR init) |
| (raw LBA 16384) | — | — | — | u-boot.itb |
| p1 boot | 256MB | LABEL=boot | ext4 | Kernel FIT image + DTB + DTBO |
| p2 rootfs | 6GB | LABEL=rootfs | ext4 (ro) | Ubuntu 只读基础系统 |
| p3 overlay | 512MB | LABEL=overlay | ext4 (rw) | OverlayFS upper + work 目录 |

## 启动流程

```
BootROM → idbloader (LBA 64) → U-Boot (LBA 16384) → boot.img (FIT: kernel+DTB)
  → 内核挂载 rootfs (/ro, ro) + overlay (/overlay, rw)
  → initramfs hook: overlayfs merge → / (writable)
```

## Overlay 机制

采用 **base + local 融合** 方式，类似 `~/.claude/` 与 `.claude/` 的合并策略：

```
debian/overlay/          ──copy──► rootfs/    (SDK 基础)
ubuntu/overlay/overlay/  ──copy──► rootfs/    (本地覆盖，同名文件优先)
```

- SDK 的 `debian/overlay*` 提供基础配置
- `ubuntu/overlay/` 下的同名目录提供本地覆盖
- 同名文件：本地覆盖 SDK
- 不同文件：两边都生效 (union)

### Debug overlay 开关

Debug overlay (`debian/overlay-debug`) 包含测试工具、调试脚本，仅在开发阶段需要：

```bash
# 开发 — 启用
OVERLAY_DEBUG_ENABLE=yes bash ubuntu/build.sh

# 发版 — 禁用 (默认)
bash ubuntu/build.sh
```

配置在 `boards/rk3576.conf`：

```bash
OVERLAY_DEBUG_ENABLE="${OVERLAY_DEBUG_ENABLE:-no}"  # 默认关闭

OVERLAYS=(
    "${SDK_PATH}/debian/overlay|${PROJECT_DIR}/overlay/overlay"
    "${SDK_PATH}/debian/overlay-firmware|${PROJECT_DIR}/overlay/overlay-firmware"
)

# 条件添加 debug overlay
if [[ "${OVERLAY_DEBUG_ENABLE}" == "yes" ]]; then
    OVERLAYS+=( "${SDK_PATH}/debian/overlay-debug|${PROJECT_DIR}/overlay/overlay-debug" )
fi
```

## 包定制（添加 / 移除）

### 添加包：`extra-packages`

在镜像定义 YAML 中直接列出：

```yaml
# image-definition.yaml
customization:
  extra-packages:
    - name: build-essential
    - name: vim
```

### 移除包：seed blacklist

采用 germinate 种子的 blacklist 机制，移除上游种子默认引入的包。
编辑本地覆盖文件：

```
ubuntu/ubuntu-build-service/seeds-local/blacklist
```

**一行一个包名**，支持 `#` 注释：

```
# blacklist: 桌面组件（嵌入式/服务器不需要）
gnome-games
gnome-sudoku
thunderbird
libreoffice-core
rhythmbox

# blacklist: 后台更新服务（嵌入式设备不需要）
unattended-upgrades
update-notifier
update-notifier-common
update-manager-core
ubuntu-release-upgrader-core
```

blacklist 在 germinate 解算依赖**之前**生效，包从头不会被安装——比安装后再 purge 更干净、镜像更小。

> **原理：** 构建脚本 `build.sh` 将 `seeds/`（上游基础）+ `seeds-local/`（本地覆盖）
> 合并为一个 git 仓库，ubuntu-image 从该仓库读取种子来决定安装哪些包。

### 其他种子定制

| 目的 | 文件 |
|------|------|
| 调整种子继承关系 | `seeds-local/STRUCTURE` |
| 覆盖特定种子内容 | `seeds-local/server-minimal` 等 |

## 内核模块与驱动器

### 内核模块列表 (`KERNEL_MODULES_LIST`)

构建时自动从 `kernel-6.1/` 编译树拷贝 `.ko` 文件到 rootfs `/usr/lib/modules/`：

```bash
# boards/rk3576.conf
KERNEL_MODULES_LIST=(
    # "drivers/net/wireless/rockchip_wlan/rkwifi/bcmdhd/bcmdhd.ko"
    # "drivers/some/module.ko"
)
```

- 相对路径基于内核编译目录 (`kernel-6.1/`)
- 适用于内核树内编译好的模块

### 外部内核模块 (`WIFIBT_MODULES`)

从 `external/rkwifibt/` 源码编译外部 WiFi/BT 驱动：

| 配置值 | 编译目标 |
|--------|----------|
| `bcmdhd_pcie` (默认) | Broadcom PCIe (AP6275P) |
| `bcmdhd_sdio` | Broadcom SDIO (AP6212/AP6256) |
| `bcmdhd` | PCIe + SDIO 双版本 |
| `realtek` | Realtek rtl8xxx 系列 |
| `all` | 全部驱动 |

### DTS Overlay

在 `boot-assets/overlays/` 中放置 `.dts` 源文件，构建时自动编译为 `.dtbo`：

```
boot-assets/overlays/
├── example-overlay.dts    # 源文件 (手动创建)
└── example-overlay.dtbo   # 编译产物 (自动生成)
```

Overlay 示例 (`example-overlay.dts`)：

```dts
/dts-v1/;
/plugin/;

&i2c4 {
    touchscreen@5d {
        compatible = "goodix,gt911";
        reg = <0x5d>;
    };
};
```

编译后的 `.dtbo` 安装到 `/boot/overlays/`，U-Boot 通过 extlinux.conf 加载。

## 内核更新

镜像采用 **只读 base + OverlayFS** 设计：

```
p2 rootfs (ext4, ro)     ← 不可变基础系统
p3 overlay (ext4, rw)    ← 可写层 (upper + work)
  └─ 合并后: / (writable)
```

烧录后所有分区内容只读（boot + rootfs），运行时通过 overlay 分区承载所有写入。

更新内核时重新烧录 boot 分区即可。详见启动流程章节。

## 远程原生构建 (arm64 Native, 推荐)

在 arm64 目标板上直接构建 rootfs，**无 qemu，零 segfault**。

### 配置 .env

```bash
BUILD_MODE="remote"
BUILD_HOST="192.168.1.XXX"
BUILD_USER="root"
```

目标板需满足：
- Ubuntu 系统运行中
- SSH 已启用
- 已安装 `ubuntu-image` snap 和 `debootstrap`

### 流程

```
build.sh 检测 BUILD_MODE=remote
  → rsync ubuntu/ → 目标板
  → ssh 目标板 native build (~30-60 min)
  → scp rootfs.tar.gz 回来
  → 本地打包 update.img
```

### 对比

| | x86 本地 | arm64 远程 |
|---|---|---|
| Desktop 成功率 | ~30% (qemu segfault) | 100% |
| 时间 | 4-6 小时 | 30-60 分钟 |

## 交叉编译 (x86 本地构建)

根据主机架构选择官方推荐的编译方式：

| 主机架构 | rootfs 构建 | 包重建 | 编译时间 |
|----------|------------|--------|----------|
| **amd64** | QEMU user static (两阶段) | `sbuild --host=arm64` | 3-4 小时 |
| **arm64** | Native debootstrap | `dpkg-buildpackage` | 15-20 分钟 |
| **CI amd64** | QEMU (两阶段+py3compile 补丁) | 跳过(用预编译 .deb) | ~1 小时 |
| **CI arm64** | Native (自托管 runner) | Native build | ~20 分钟 |

### amd64 主机

`build.sh` 自动检测跨架构并注入 qemu-aarch64-static：

1. `--thru create_chroot` → 创建 chroot
2. 复制 `qemu-aarch64-static` 到 chroot
3. `--resume` → 继续包安装

```bash
sudo apt-get install qemu-user-static binfmt-support
```

### arm64 主机 (推荐，生产构建)

```bash
# 无需 QEMU，直接原生编译
bash ubuntu/build.sh
```

## 关键设计决策

1. **ubuntu-image 构建 rootfs，手动组装 bootloader** — ubuntu-image 的 U-Boot 支持不完整，只处理 SecureBoot 文件
2. **只读 rootfs + OverlayFS 覆盖层** — 断电安全，系统升级只需替换 rootfs 分区
3. **DTS Overlay 支持** — 设备树覆盖层方便修改硬件配置，无需重新编译完整 DTB
4. **base + local overlay 融合** — SDK overlay 为基础，本地 overlay 选择性覆盖，不修改 SDK 文件

## SDK 依赖

`SDK_PATH` 自动从脚本位置推导，无需手动设置。推导逻辑：

```
ubuntu/ubuntu-build-service/build.sh  →  PROJECT_DIR = ubuntu/  →  SDK_PATH = repo root
```

也可手动指定：`SDK_PATH=/path/to/sdk bash ubuntu/build.sh`

## 新 SOC 移植

### 目录结构

```
boards/
├── rk3576/                    # 每个板子一个目录
│   ├── rk3576.conf            #   板级配置 (必须)
│   ├── parameter.txt          #   分区布局 (可选，默认用 SDK 的)
│   └── package-file           #   打包清单 (可选，默认用 SDK 的)
├── package-check.conf         # 全局：包检查列表
└── board-template/            # 模板
    └── board-template.conf
```

### 移植步骤

```bash
# 1. 复制模板
cp -r boards/board-template boards/rk3588
mv boards/rk3588/board-template.conf boards/rk3588/rk3588.conf

# 2. 编辑板级配置
vim boards/rk3588/rk3588.conf
# 必填：BOARD_NAME, SOC_MODEL, 分区布局, 启动文件
# 可选：UPDATE_PARTITIONS (去掉不需要的分区)

# 3. (可选) 创建自定义分区和打包清单
vim boards/rk3588/parameter.txt
vim boards/rk3588/package-file

# 4. 更新 .env
echo 'SOC_MODEL="rk3588"' >> .env
echo 'BOARD="rk3588"' >> .env

# 5. 构建
bash ubuntu/build.sh
```

### rk3576.conf 关键配置

| 变量 | 说明 | 示例 |
|------|------|------|
| `SOC_MODEL` | SoC 型号 | `rk3576` |
| `UPDATE_PARTITIONS` | 包含的分区列表 | `"uboot misc boot recovery backup rootfs oem"` |
| `ROOTFS_OVERLAY_ENABLE` | 是否启用 overlayfs | `yes` / `no` |
| `ROOTFS_LABEL` / `OVERLAY_LABEL` | 分区标签 | `rootfs` / `overlay` |
| `WIFIBT_MODULES` | WiFi/BT 驱动类型 | `bcmdhd_pcie` |

详见 [SoC 移植指南](docs/PORTING.md) 和 [架构文档](docs/ARCHITECTURE.md)。
