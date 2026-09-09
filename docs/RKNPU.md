# RKNPU2 运行时与验收

Ubuntu 镜像把 SDK 的 RKNPU2 预编译输入重新打包为三个运行时 DEB：

- `librknnrt2`：multiarch 路径下的 `librknnrt.so` 和通用 NPU udev 权限；
- `rknn-server`：`rknn_server`、`rknn_common_test` 和 systemd 服务；
- `rknn-models`：SDK 提供的 MobileNet 模型和 dog/cat 输入。

闭源库、测试二进制和模型均在构建时从 `SDK_DIR` 读取，不进入 Git。模型目录从
SDK `rknpu2.tar` 动态收集，目标 QA 根据设备树 compatible 选择对应模型，不固定
DRM minor、设备地址或单一 SoC。

## 构建与集成

在 ARM64 native 构建主机执行：

```bash
./scripts/build-local-debs.sh rknpu2
SOC_MODEL="<soc>" SDK_KERNEL_CONFIG="<kernel-build-config>" \
  ./scripts/stage-sdk-assets.sh
./build.sh overlay-root
```

构建会同时生成 `librknnrt-dev`，供应用开发使用；platform-assets 和 rootfs 默认只
集成三个运行时包。所有运行时包均被 hold，避免 Ubuntu 软件源替换 vendor ABI。
内核最终配置必须含 `CONFIG_ROCKCHIP_RKNPU=y`。

## 非 root 权限

udev 按 RKNPU 驱动匹配 DRM render 节点，不依赖 `renderD129` 等动态编号；旧驱动的
`/dev/rknpu` 也使用相同策略。节点归 `render` 组、权限 `0660` 并带 `uaccess`。
`ubuntu-firstboot` 创建的客户账户默认加入 `render` 组。

## 目标板验收

使用普通账户直接运行；若由 root/自动化调用，脚本会选择 firstboot 客户账户或第一个
有效普通账户，通过 `runuser` 执行全部推理：

```bash
/usr/libexec/ubuntu-rknpu-qa
```

验收固定运行 MobileNet 200 次，并要求：

- 推理实际由非 root 账户完成；
- 恰好得到 200 个可解析的耗时样本；
- dog 样例 Top-1 class 为 156，confidence 不低于 0.5；
- 每次推理延迟小于默认 15 ms。

成功证据示例：

```text
RKNPU_NONROOT_OK user=<user> device=/dev/dri/renderD<n>
RKNPU_SOAK_OK completed=200 expected=200 top1_class=156 top1=0.935059 min_ms=2.10 avg_ms=2.13 max_ms=2.45 limit_ms=15 user=<user> model=RK3576
```

更换模型或性能门限时可显式设置 `RKNPU_EXPECTED_TOP1_CLASS`、`RKNPU_MIN_TOP1` 和
`RKNPU_MAX_LATENCY_MS`；量产验收应记录实际输出，不以包存在或总状态 `pass` 代替。
