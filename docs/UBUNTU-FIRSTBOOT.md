# 客户首次启动账户创建

交付镜像默认启用 ubuntu-firstboot，不创建预置普通用户或密码，root 保持锁定。
首次启动在实际 console 提示客户选择管理员用户名并设置密码；不再强制第二次改密。
完成后移除 pending 标记和临时 SSH 限制。后续启动不会再次要求建号。

构建默认 `ENABLE_CONSOLE_FIRSTBOOT=yes`、`FIRSTBOOT_PROFILE=server`。
Desktop 可选择 desktop 或 desktop-xfce profile，自动登录默认关闭。

## 客户量产定制与回滚

账户引擎、默认启用策略、cloud-init 的 `users: []` 和无预置凭据检查在同一提交。
需要固定量产账户的客户，先 revert 本 firstboot 提交，再在
`config/ubuntu-image/resolute-server-arm64.yaml.in` 配置自己的 cloud-init 账户策略，
`chpasswd.expire` 设为 false，使用客户提供的密码哈希。凭据不提交到公共源码。
回滚恢复的是此前账户模板，客户必须替换成自己的配置并重新验收后交付。

仅设置 `ENABLE_CONSOLE_FIRSTBOOT=no` 不会自动提供账户；禁用交互前必须准备
其他账户配置，不能交付一个既无账户也无建号入口的镜像。

## 验证

`bash tests/host/test-firstboot.sh` 检查默认启用、显式关闭、无预置凭据、用户名验证、
console/getty 所有权和 EOF 后密码输入。`tests/target/test-firstboot.sh default`
检查待初始化镜像；完成建号后执行 `completed`，再重启确认不再次提示。
中断初始化时 pending 保留，下次启动继续。硬件验证结果单独保存，不以源码测试代替。
