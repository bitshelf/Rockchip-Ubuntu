# XFCE + Xserver 桌面

精简镜像复用 `xfdesktop4-data` 自带的蓝色壁纸，为发行包默认引用的
`xubuntu-wallpaper.png` 提供兼容链接，避免缺少完整 Xubuntu artwork 时显示纯黑背景。
该设置只补齐缺失的默认文件，保留用户自行选择的壁纸。

`./build.sh desktop-xfce` uses the shared Server seed and firstboot account
policy with an explicit XFCE package list. LightDM starts `xfce.desktop` on
a real Xorg server. GNOME Shell, GDM and Ubuntu's GNOME session are excluded
from the package boundary; the existing GNOME and Server products retain
independent manifests.

`config/desktop/xfce/20-rockchip-display.conf` selects the `rockchip` KMS
controller as Xorg's primary display using an OutputClass and the modesetting
driver. Other DRM devices, including NPU nodes, must not become the primary
display. The policy matches the kernel driver rather than a fixed card number
or board bus ID. Physical acceptance checks both the KMS display descriptor
and the Mali rendering descriptor opened by Xorg.

Enable `desktop-xfce` in `artifacts/build.json` alongside the desired
variants, pack/upload the artifacts directory and push the source. Forgejo
and GitHub build all three variants on native ARM64. No board name or SoC
is encoded in the XFCE installer; kernel, DTB, modules and local DEBs still
come from the external platform assets.

Fcitx5 and librime use Ubuntu packages. Every desktop overlay fetches the
latest Rime Ice commit, recording its provenance. Xsession selects Fcitx5,
and XFCE uses its classic input panel instead of the GNOME Shell extension.
Xserver screensaver/DPMS and the XFCE power-manager display blank timers are
disabled when the extension is available; an Xserver without the DPMS extension
also cannot perform DPMS blanking. No QA user, password, key or automatic login is added to a factory
image.

On a physical display, run `tests/target/test-xfce.sh` as root to check the
active local X11 session, Mali GLX renderer, Xorg GPU device access and
blanking state. As the desktop user with its DISPLAY/XAUTHORITY and session
bus, run:

```bash
CHROMIUM_QA_SESSION=x11 CHROMIUM_MPP_VIDEO=/absolute/real-video.mp4 \
  /usr/libexec/ubuntu-chromium-mpp-qa
CHROMIUM_QA_SESSION=x11 WEBGPU_REAL=1 WEBGPU_BACKEND=gles-compat \
  /usr/libexec/ubuntu-webgpu-vulkan-qa
GDK_BACKEND=x11 GTK_IM_MODULE=fcitx QA_INPUT_INJECT=1 \
  /usr/libexec/ubuntu-xfce-rime-input-qa
```

The input test focuses its own GTK window and commits `你好` using Xserver
input injection. It requires Fcitx's actual classic panel. GTK focus and
Fcitx input-context registration are asynchronous: the test waits for a
registered context, then confirms the active state and selected Rime method
before injecting keys. A successful switch command alone is insufficient.
The video test
still requires V4L2VideoDecoder, real decoded footage and increasing MPP
interrupt counts; changing the display backend does not accept software
fallback. The X11 compatibility path uses ANGLE OpenGLES over Mesa EGL,
with X11 display connections opened before the early GPU sandbox. Experimental PanVK/core remains a separate opt-in test with the
same readback bridge described in WEBGPU-VULKAN-QA.md.

Use the `ubuntu26-xfce` candidate policy in RELEASE-GATES.md. A native build
or synthetic host fixture is not physical XFCE acceptance. Export separate
image/target/reboot/one-hour soak evidence before promotion. Loaded RT and
NPU performance qualification remains separate from functional porting.

The seed explicitly selects `xfce-polkit`. Ubuntu 26 network-manager-applet
and nm-connection-editor require `gnome-shell | policykit-1-gnome |
polkit-1-auth-agent`; selecting the XFCE provider prevents APT from bringing
in GNOME Shell through the first alternative. The manifest gate rejects any
GNOME Shell leakage.

## 并发会话下的状态检查

桌面验收从 logind 一次读取每个会话的属性快照，跳过枚举后已退出的临时
SSH/PAM 会话。有效的本地桌面、物理显示和 GPU 检查仍必须全部通过；没有
符合条件的桌面时仍返回失败。混合长稳测试不得把临时会话消失误判为桌面退出。
