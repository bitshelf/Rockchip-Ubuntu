# ADB USB gadget 移植与 QA

Ubuntu archive 的 `adbd` 包随 Server rootfs 安装。板级集成只替换 USB gadget
生命周期和 systemd 启动策略，不维护 adbd 私有 fork。

`adbd.service` 默认以 root 运行并保留 initial network namespace，不设置
`PrivateNetwork`、capability allowlist、system-call allowlist 或额外的地址族限制。
因此 `adb shell` 可执行与串口 root console 相同的诊断，尤其能看到相同的网络接口：

```bash
adb shell id
adb shell 'readlink /proc/1/ns/net; ip -c a'
```

USB gadget 从 `/sys/class/udc/` 动态选择可用控制器，不绑定 SoC 寄存器地址。
FunctionFS 描述符就绪后才绑定 UDC，避免 adbd 与 ConfigFS 的启动竞态。

## 串口与 ADB 对照 QA

烧录后分别从串口 root console 和开发主机执行同一个测试：

```bash
# 串口
sudo /path/to/tests/target/test-adb.sh

# 开发主机
adb shell /path/to/tests/target/test-adb.sh
```

两次都必须返回 `result=pass`，并且 `network_namespace`、`interface_count` 和
`ip_color_sha256` 完全相同。测试使用 `ip -o -c address` 生成稳定摘要；人工验收再
直接比较两端的 `ip -c a`。地址租约剩余时间会自然变化，不作为内容差异。

ADB 只通过 USB FunctionFS 集成。功能不通过创建私有 network namespace 来隔离，
也不通过将 daemon 降权来限制调试范围；产品若需要限制物理 USB 调试，应在单独的
量产策略中整体关闭 ADB，而不是交付一个无法完成板级诊断的半权限 shell。
