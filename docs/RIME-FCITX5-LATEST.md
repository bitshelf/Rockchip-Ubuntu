# GNOME Fcitx5/Rime latest 资源

Fcitx5、fcitx5-rime 和 librime 使用 Ubuntu 软件包，不从 latest 源码重编译。

GNOME 默认启用 Kimpanel。Fcitx5 5.1.19 的七秒诊断定时器可能先于异步
面板查询完成，造成“推荐安装 Input Method Panel”误报。GNOME 新用户仅隐藏
`wayland-diagnose-gnome` 这一安装提示，其他通知保持启用；这不修复上游竞态。
实机中文输入测试同时要求 `CurrentUI=kimpanel` 和 GTK Wayland 输入“你好”，
因此缺失面板仍会导致验收失败。已有用户需要更新自己的
`~/.config/fcitx5/conf/notifications.conf`，保留原有隐藏项，并重新加载 notifications 插件。
GNOME Wayland 的候选面板使用 Kimpanel。当前 Resolute 软件源未提供该扩展，
通过 `scripts/build-local-debs.sh kimpanel` 在原生 ARM64 主机构建本地 DEB。
扩展固定为上游第 92 版（明确支持 GNOME 48/49/50），下载 URL 与 SHA256
在打包脚本中固定，安装到系统扩展目录，并由 GNOME 默认配置启用。
这不改变 Fcitx5/librime 使用 Ubuntu 包及 Rime Ice 每次 latest 的策略。
`tests/target/test-gnome-rime-input.py` 在专用 GTK4 Wayland 窗口中通过
QA ydotool socket 输入 `nihao` 和空格，要求 Fcitx 当前方案为 Rime、
输入框实际提交 `你好`，并保存结果 JSON。它需显式设置
`QA_INPUT_INJECT=1`，窗口获得焦点后才注入按键；只测试引擎转换不能
代替这一桌面输入检查。
Desktop 每次组装调用 `scripts/install-rime-ice.py`，重新请求
`https://github.com/iDvel/rime-ice/releases/latest/download/full.zip`，不固定 tag。
脚本拒绝绝对路径、目录穿越和符号链接，检查方案与许可证文件。

资源播种到 `/etc/skel/.local/share/fcitx5/rime`；已有默认 `ubuntu` 账户也更新，
并修正 UID/GID。请求 URL、最终重定向 URL 与 SHA256 保存到
`/usr/share/doc/rime-ice/SOURCE`，用于追溯该镜像实际输入。

`git revert 640d807` 回滚 latest 资源与桌面播种功能，不移除先前加入的 Ubuntu
输入法包。`tests/host/test-rime-ice-download.py` 验证连续两次构建均重新下载。
只有显式离线构建才使用 `RIME_ICE_URL` 或 `--archive` 覆盖默认输入；使用归档
时不会联网解析 latest，证据必须注明该例外。

平铺 ZIP 解压到私有临时目录后，安装器把资源根目录设为 0755，避免把临时
目录的 0700 权限复制进 `/etc/skel`，导致新桌面用户无法读取方案。主机测试
验证两次组装分别下载新内容、记录对应 SHA256，并拒绝目录穿越；实机 GTK4
Wayland 输入结果及原始日志保存在 Git 忽略的输出目录。
