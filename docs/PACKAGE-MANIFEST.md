# 软件包版本清单与可选冻结构建

默认从当前配置的软件源安装最新可选版本。只有显式指定
`ROOTFS_PACKAGE_MANIFEST`，或在外部 `artifacts/build.json` 中为某个产品指定
`package_manifests`，才启用版本冻结。目录里存在清单文件不会自动启用冻结。

## 导出

正常执行 `server` / `desktop` / `desktop-xfce` 和 `overlay-root` 后，会生成：

- `build/<variant>/images/<rootfs.erofs.img>.manifest`：最终 rootfs 的完整 DEB 清单。
- 对应 `.manifest.sha256`：清单校验和。
- `artifacts/<variant>/packages.manifest`：`build-inputs.py build` 导出的稳定文件名。

清单从最终 rootfs 的 dpkg 数据库导出，包含基础系统、Chromium、本地运行库和
被 hold 的软件包；不包含已卸载、仅剩配置文件的软件包。不完整的 dpkg 安装状态
会使导出失败。原有 `ubuntu-26.04-*.manifest` 是 ubuntu-image 基础层的清单，
继续保留，但不能用它锁定包含本地 DEB 的最终镜像。

```text
# ubuntu-package-manifest-v1
# package	version	architecture
bash	5.3-2ubuntu1	arm64
fonts-noto-cjk	1:20240730+repack1-1	all
```

上面仅展示格式；实际重建须使用完整导出文件，不能只截取几行。

也可以在 ARM64 目标系统上导出当前安装状态：

```bash
python3 scripts/package-manifest.py export --rootfs / --output /tmp/packages.manifest
```

该命令只读 dpkg 状态，不安装或升级软件。运行中的机器可能已被用户改动；交付
镜像的准确清单应使用构建阶段从最终 rootfs 导出的文件。

## 本地冻结构建

下载清单时先在其所在目录校验对应 SHA256，再保存一份清单，为同一次构建的基础层和最终层同时指定它。使用正常平台资产配置，
并先按既有流程构建相同版本的 update-engine DEB：

```bash
export ROOTFS_PACKAGE_MANIFEST="$PWD/artifacts/manifests/server.manifest"
./build.sh update-engine
./build.sh server
./build.sh overlay-root
```

GNOME 使用 `./build.sh desktop`，XFCE 使用 `./build.sh desktop-xfce`，并分别提供
各自的完整清单。Server 清单不能直接用于桌面镜像。

恢复默认最新版本：

```bash
unset ROOTFS_PACKAGE_MANIFEST
# 若 .env 中也设置了该变量，请清空该项。
```

## CI 冻结构建

输入仍放在被 Git 忽略的 `artifacts/`，不增加板级 CI 参数。
例如复制清单到 `artifacts/manifests/server.manifest` 后，在 `artifacts/build.json`
的原有字段外增加：

```json
{
  "package_manifests": {
    "server": "manifests/server.manifest",
    "desktop": "manifests/desktop.manifest"
  }
}
```

这是应合并到已有 build.json 的字段，不能用上述片段覆盖整份文件。
未列出的产品保持默认最新版本。删除整个 `package_manifests` 字段即可恢复所有
产品的默认行为。上传工具会将指定清单随平台输入一起打包，并校验整个输入包 SHA256。

```bash
python3 scripts/publish-build-inputs.py github --repository owner/repository
# 推送下一个版本标签，按现有流程构建并发布镜像。
```

每种新发布镜像会同时附带 `<update.img>.manifest` 和对应 SHA256；构建记录还包含
清单哈希和输入锁清单哈希。普通分支构建的清单在 Actions 产物中。

## 冻结策略与失败行为

- 在 ubuntu-image 创建 chroot 后、安装/升级目标软件前，安装临时 APT preferences。
  归档软件包指定精确版本，允许构建过程降级，并禁止引入清单外的新包。
- 本地 DEB 可能替换归档同名软件包，例如定制 v4l-utils。构建基础层时允许其临时
  归档依赖，最终层必须安装输入 DEB 的精确版本；本地 DEB 控制信息与清单不符即失败。
- 最终 EROFS 生成前，严格比较全部包名、版本、架构。缺包、多包或版本不一致都失败，
  不接受静默回退到新版本。成功后移除临时冻结配置，不改变客户系统日后的 APT 策略。
- 旧 DEB 若已从当前软件源下架，版本清单无法恢复该文件。需保留对应 DEB 并通过现有本地包安装配置选中它，或将
  `UBUNTU_PORTS_MIRROR` 指向保留这些版本的快照/自建仓库。无法获得精确版本时构建失败。

## 重建边界

这里保证的是最终 **DEB 软件包集合、版本和架构一致**，不是镜像逐字节相同。
还应保留相同源码、平台输入包（内核、DTB、KO、本地 DEB）、构建工具与软件源快照。
Snap 的 revision、Rime Ice 词库归档、时间戳及生成文件不由 DEB 清单冻结。
Rime Ice 默认每次解析 latest 的现有行为保持不变；需要完整复现桌面数据时，另行指定
相同的 `RIME_ICE_ARCHIVE`。若要求完全相同的镜像字节，优先保存原镜像及其 SHA256。

实现依据：[APT preferences](https://manpages.debian.org/stable/apt/apt_preferences.5.en.html)
和 [ubuntu-image 镜像定义](https://github.com/canonical/ubuntu-image/blob/main/internal/imagedefinition/README.rst)。
