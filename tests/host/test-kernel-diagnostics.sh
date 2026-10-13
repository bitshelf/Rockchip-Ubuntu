#!/usr/bin/env bash
set -Eeuo pipefail
bash -n tests/target/test-kernel-diagnostics.sh tests/target/test-kernel-log-allowlist.sh
grep -Fq 'CONFIG_PSTORE_RAM=y' config/kernel/diagnostics.conf
grep -Fq 'KERNEL_LOG_ALLOWLIST_OK' tests/target/test-kernel-log-allowlist.sh
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/bin"
cat >"$tmp/bin/dmesg" <<'MOCK'
#!/bin/sh
if [ "$#" -gt 0 ]; then cat "$QA_ERROR_LOG"; else cat "$QA_FULL_LOG"; fi
MOCK
chmod +x "$tmp/bin/dmesg"
printf '%s\n' 'rockchip-vop2 27d00000.vop: failed to init opp info' >"$tmp/errors"
printf '%s\n' 'rockchip-vop2 27d00000.vop: Unsupported VOP aclk dvfs' >"$tmp/full"
check_log() {
    PATH="$tmp/bin:$PATH" QA_ERROR_LOG="$tmp/errors" QA_FULL_LOG="$tmp/full" \
        KERNEL_ERROR_ALLOWLIST=config/kernel/rk3576-kernel-errors.allow \
        bash tests/target/test-kernel-log-allowlist.sh
}
check_log >"$tmp/result"
grep -Fq VOP_FIXED_CLOCK_FALLBACK_CONFIRMED "$tmp/result"
: >"$tmp/full"
if check_log >"$tmp/result" 2>&1; then
    echo 'VOP OPP failure was accepted without a confirmed fallback' >&2; exit 1
fi
printf '%s\n' 'es8389 4-0010: ASoC: ADC Mixer DAPM update failed: -6' >"$tmp/errors"
if check_log >"$tmp/result" 2>&1; then
    echo 'audio hardware failure was accepted by the allowlist' >&2; exit 1
fi
echo "Kernel log/pstore/watchdog QA contract passed"
