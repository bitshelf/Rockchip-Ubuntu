# 蓝牙外部输入

蓝牙的固件、ARM64 初始化程序、服务及设备配置不提交到 Git。将它们放到
`artifacts/bluetooth/`；本地构建及上传后的 CI 构建都会自动集成，无需添加板型或 CI 参数。
该目录已由 `/artifacts/` 的 Git 忽略规则排除。没有此目录时，不增加蓝牙资产或相关软件包。

## 目录规范

```text
artifacts/bluetooth/
├── config.json                         # 可选的软件包依赖
└── rootfs/
    ├── usr/lib/firmware/<provider>/...   # 固件
    ├── usr/libexec/platform-bluetooth/   # ARM64 程序或带 #! 的初始化脚本
    ├── usr/lib/systemd/system/
    │   └── platform-bluetooth.service   # 可选；构建时自动启用
    ├── etc/platform-bluetooth/          # UART、速率及其他设备配置
    └── etc/modprobe.d/
        └── platform-bluetooth.conf      # 可选的模块参数
```

`rootfs/` 下的文件按原相对路径进入镜像。只接受上述路径；服务和模块配置名可使用
`platform-bluetooth` 前缀及字母、数字、下划线、点、连字符。所有匹配服务均启用到
`multi-user.target`。服务本身应配置正确的依赖、启动条件及重启策略。

提供者负责准备匹配的固件、初始化逻辑和服务；通用导入器不会猜测芯片、UART、GPIO、
MAC 或供电顺序，也不会在构建主机上运行初始化程序。标准内核驱动自行加载固件时，
可以只提供固件，不提供初始化服务。

KO 继续使用 [平台资产目录](ARTIFACTS.md) 的 `modules/lib/modules/<kernel-release>/`
及模块清单；不要复制到蓝牙目录。KO 必须匹配所选内核。依赖的 DEB 同样继续放到平台资产的
`debs/`，并使用既有安装清单。

可选 `config.json`：

```json
{
  "schema": "linux-bluetooth-assets-v1",
  "packages": ["bluez"]
}
```

没有配置文件时默认增加 `bluez`。`packages` 只接受 APT 软件包名，版本仍遵循项目的
默认最新或显式 [版本清单](PACKAGE-MANIFEST.md) 策略。自带程序的运行库也需列为依赖；
不要依赖另一台开发机器上偶然安装的软件包。

## 构建与上传

在仓库根目录预检：

```bash
python3 package/bluetooth/import-assets.py check --inputs artifacts/bluetooth
```

按 [上传指南](UPLOAD-ASSETS.md) 使用现有 `build-inputs.py pack` 和上传命令。
输入包会自动携带 `bluetooth/`，在 GitHub 与 Forgejo 的 Server、GNOME、XFCE 构建中使用。
修改目录后需重新打包、上传，并使用新输入包的 SHA256；旧发布附件不会随本地文件变化。
无需 `git add` 或 `git push` 这些文件。

导入器拒绝符号链接、特殊文件、错误架构的 ELF 初始化程序及与镜像已有文件内容冲突的路径。
初始化程序安装为 `0755`，固件、服务与配置为 `0644`，因此上传包不需要保留执行位。
最终镜像含 `usr/share/platform-bluetooth/assets.json`，记录文件 SHA256、权限和服务；
EROFS 的 `.build-info` 记录 `bluetooth.assets.sha256`，便于核对实际集成输入。

## 验收边界

文件集成成功与硬件通过是两项检查。启动后应检查提供者服务、HCI 控制器、固件加载日志，
再用已授权的蓝牙对端完成发现、首次配对和实际传输。没有对端时不能声称完成配对或传输验收。
不要将设备地址、配对密钥或 `/var/lib/bluetooth/` 的运行数据提交到 Git 或打入通用镜像。
