# 自包含的 ARM64 构建输入

板级选择全部放在 Git 忽略的 `ubuntu/artifacts/`。CI 不设置 SoC、DTB、GPU
或内核参数；上传工具只自动更新输入包的 URL 和 SHA256 定位信息。

```text
artifacts/
  build.json
  platform-assets/<soc>/
    asset-info
    SHA256SUMS
    boot/               # Image、基础 DTB、kernel.config、logo、可选 DTBO
    modules/            # 保持 lib/modules/<kernel-release> 的目录结构
    debs/               # ARM64 DEB 和允许的 architecture=all 包
    iqfiles/            # 可选外部相机 IQ 数据
  bluetooth/            # 可选：外部蓝牙固件、初始化程序、服务和设备配置
  sources/
    update-engine.tar
    update-engine.tar.source-info
  ubuntu-rootfs.img     # 回传的文件系统镜像，不作为输入上传
```

`platform-assets/<soc>/` 的实际文件布局与 manifest 由
`scripts/stage-sdk-assets.sh` 生成和校验，模块文件不平铺，DEB 不重新命名。
`sources/` 通过 `scripts/stage-update-engine-source.sh` 生成。所有二进制、
产品 DTB、IQ、凭据和实机报告均不进入 Git。

`build.json` 示例（在 artifacts 内编辑，换平台不改 CI）：

```json
{
  "schema": "ubuntu-build-inputs-v1",
  "soc": "rk3588",
  "variants": ["server", "desktop", "desktop-xfce"],
  "gpu_stack": "panfrost",
  "chromium_webgpu_backend": "auto",
  "boot": {
    "base_dtb": "board.dtb",
    "cmdline": "root=PARTLABEL=rootfs rootfstype=erofs rootwait ro"
  }
}
```

`gpu_stack` 必须与资产包的内核和用户态相匹配。只有经过硬件验证的平台才选择
`gles-compat`；`auto` 保留浏览器自身选择。示例不代表 RK3588 已验收。

```bash
python3 scripts/build-inputs.py check
python3 scripts/publish-build-inputs.py forgejo \
  --server http://192.168.1.209:3000 --repository ubuntu/ubuntu --build
# Forgejo 跑通后，再发布同一批输入：
python3 scripts/publish-build-inputs.py github \
  --repository bitshelf/Rockchip-Ubuntu --build
```

Forgejo 使用外部 `ASSET_TOKEN`，或外部 `FORGEJO_ADMIN_USER`、
`FORGEJO_ADMIN_PASSWORD`；GitHub 使用外部 `GH_TOKEN`。命令行打包整个输入集合，
上传不可变版本并自动设置仓库 `BUILD_INPUTS_URL`、`BUILD_INPUTS_SHA256`。
更换 RK3588 时替换 artifacts 的清单与资产，重新运行同一上传命令即可。
私有附件另用 CI secret `BUILD_INPUTS_AUTH_HEADER`，凭据不放在 artifacts。

先推送源码，再使用上传命令的 `--build` 启动 rootfs workflow；可用
`--ref` 选择源码分支，不传时使用默认分支。仅上传时省略 `--build`，
随后也可从 Actions 网页启动。平台参数仍全部来自 artifacts。
ARM64 runner 下载并校验输入包，在本机运行 ubuntu-image，再生成 EROFS rootfs、
ext4 boot/userdata。每个变体附件包含 `ubuntu-rootfs.img` 与 SHA256，适合分区
烧录和 SDK 打包，不能当作整盘镜像直接 dd。回传目标变体到
`ubuntu/artifacts/ubuntu-rootfs.img` 后，`rockdev/rootfs.img` 指向它。

镜像构建成功只证明流水线和文件系统产物；实机 reboot/soak/promotion
使用独立门禁，不能由 CI 编译结果替代。

命令行与网页上传的完整步骤见 [UPLOAD-ASSETS.md](UPLOAD-ASSETS.md)。

蓝牙输入放置规范与自动集成行为见 [BLUETOOTH-ASSETS.md](BLUETOOTH-ASSETS.md)。
