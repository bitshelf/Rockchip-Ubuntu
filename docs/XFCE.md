# Ubuntu 26 XFCE + Xserver

`./build.sh desktop-xfce` uses the shared Server seed and firstboot account
policy with an explicit XFCE package list. LightDM starts `xfce.desktop` on
a real Xorg server. GNOME Shell, GDM and Ubuntu's GNOME session are excluded
from the package boundary; the existing GNOME and Server products retain
independent manifests.

Enable `desktop-xfce` in `artifacts/build.json` alongside the desired
variants, pack/upload the artifacts directory and push the source. Forgejo
and GitHub build all three variants on native ARM64. No board name or SoC
is encoded in the XFCE installer; kernel, DTB, modules and local DEBs still
come from the external platform assets.

Fcitx5 and librime use Ubuntu packages. Every desktop overlay fetches the
latest Rime Ice commit, recording its provenance. Xsession selects Fcitx5,
and XFCE uses its classic input panel instead of the GNOME Shell extension.
Xserver screensaver/DPMS and the XFCE power-manager display blank timers are
disabled. No QA user, password, key or automatic login is added to a factory
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
input injection. It requires Fcitx's actual classic panel. The video test
still requires V4L2VideoDecoder, real decoded footage and increasing MPP
interrupt counts; changing the display backend does not accept software
fallback. Experimental PanVK/core remains a separate opt-in test with the
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
