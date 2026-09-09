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

## RGA 2D 加速

RGA runtime 随镜像安装，但开发包只用于构建验收工具。目标板 QA 必须完成真实
dma-buf color fill、同步读回并输出 `RGA_SMOKE_OK`，见 [RGA.md](RGA.md)。

## MPP 视频编解码

MPP runtime 和验收工具随镜像安装。目标板必须完成同一 H.264 bitstream 的 100 帧
硬件编码和 100 帧硬件解码，见 [MPP.md](MPP.md)。

## V4L2

patched v4l-utils、libv4l-rkmpp 和独立 V4L2 QA 见
[V4L2.md](V4L2.md)。

## ISP 与 OV13855

镜像移植 RKISP/RKAIQ 服务；OV13855 仅作为可替换的摄像头验收示例。基础配置不
携带板级 IQ，产品定制通过独立提交加入匹配的 overlay、IQ 包和验收条件。真实 30 帧
摄像头 QA 见 [ISP.md](ISP.md)。

## GStreamer 与 gst-rkmpp

GStreamer 主体使用 Ubuntu 26 软件源，SDK 仅提供 Rockchip MPP 插件。目标 QA 以
100 帧 NV12 完成硬件编码、H.264 解析和硬件解码，见
[GSTREAMER.md](GSTREAMER.md)。

## ADB 调试

ADB 使用 Ubuntu `adbd` 和通用 USB FunctionFS gadget，保持 root shell 与 host
network namespace，使 `adb shell ip -c a` 与串口看到相同接口。移植与双通道 QA
见 [ADB.md](ADB.md)。
