#!/usr/bin/env bash
set -Eeuo pipefail
for f in config/kernel/rockchip_rt.config config/kernel/industrial-recommended.config config/kernel/ubuntu-common.config config/kernel/ubuntu-desktop.config; do test -s "$f"; done
grep -Fxq 'CONFIG_PREEMPT_RT=y' config/kernel/rockchip_rt.config
grep -Fxq 'CONFIG_PSTORE_RAM=y' config/kernel/industrial-recommended.config
bash -n tests/target/test-rt-cyclictest.sh
echo "RT kernel fragment contract passed"
