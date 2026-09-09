# 硬件功能与验收

[返回项目首页](../README.md) · [构建与交付流程](BUILD-WORKFLOW.md)

本页说明各功能的集成方式与验收要求，不代表所有平台或新构建镜像均已通过测试。
实际验收结果须对应目标硬件和镜像哈希；完整门禁见
RELEASE-GATES.md。

## GPU、Chromium 与中文输入

GNOME 与 XFCE 的桌面配置分别见 GNOME.md、XFCE.md。
浏览器硬件视频解码和真实视频验证见 Chromium MPP，
WebGPU/Vulkan 后端、硬件证明及限制见 WEBGPU-VULKAN-QA.md。
中文输入、引擎和词库配置见 RIME-FCITX5-LATEST.md。


## ADB 调试

ADB 使用 Ubuntu `adbd` 和通用 USB FunctionFS gadget，保持 root shell 与 host
network namespace，使 `adb shell ip -c a` 与串口看到相同接口。移植与双通道 QA
见 [ADB.md](ADB.md)。
