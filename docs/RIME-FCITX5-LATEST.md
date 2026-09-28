# GNOME Fcitx5/Rime latest 资源

桌面镜像使用 `scripts/install-rime-ice.py` 在每次构建时下载
`https://github.com/iDvel/rime-ice/releases/latest/download/full.zip`，不固定 tag。
脚本限制压缩包大小、拒绝绝对路径/目录穿越/符号链接，并要求唯一的
`rime_ice.schema.yaml`、`default.yaml` 和许可证文件。

资源同时播种到 `/etc/skel/.local/share/fcitx5/rime`；已有 `ubuntu` 账户也会更新，
并按账户 UID/GID 修正所有权。最终请求 URL、重定向 URL 和 SHA-256 写入
`/usr/share/doc/rime-ice/SOURCE`，便于追溯每次构建实际下载内容。

提交是可回滚的：

```sh
git revert <rime/fcitx5-commit>
```

回滚只移除 latest 资源安装和桌面播种，不影响 Server 镜像；下一次构建重新执行
脚本时会获取当时的 latest 版本。离线构建可设置 `RIME_ICE_URL` 或使用
`--archive`，仍会执行同样的安全校验和 provenance 记录。

平铺 ZIP 解压到私有临时目录后，安装器把资源根目录设为 0755，避免把临时
目录的 0700 权限复制进 `/etc/skel`，导致新桌面用户无法读取方案。主机测试
验证两次组装分别下载新内容、记录对应 SHA256，并拒绝目录穿越；实机 GTK4
Wayland 输入已提交“你好”，日志为 SDK 输出
`output/ubuntu-desktop-jr-20261013/qa/gnome-rime-unlocked-current.log`。
