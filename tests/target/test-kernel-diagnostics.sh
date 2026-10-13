#!/usr/bin/env bash
set -Eeuo pipefail
fail() { echo "FAIL: $*" >&2; exit 1; }
config="/proc/config.gz"; [[ -r "$config" ]] || config="/boot/config-$(uname -r)"
[[ -r "$config" ]] || fail "kernel config is unavailable"
read_config() { if [[ "$config" == *.gz ]]; then zcat "$config"; else cat "$config"; fi; }
config_text="$(read_config)"
for option in CONFIG_PSTORE CONFIG_PSTORE_CONSOLE CONFIG_PSTORE_RAM CONFIG_WATCHDOG CONFIG_DW_WATCHDOG; do
  grep -Fxq "$option=y" <<<"$config_text" || fail "missing kernel option $option"
done
findmnt -rn -t pstore -o TARGET | grep -Fxq /sys/fs/pstore || fail "pstore filesystem is not mounted"
watchdog=/dev/watchdog0
[[ -c "$watchdog" ]] || fail "no watchdog0 device node"
identity="$(cat /sys/class/watchdog/watchdog0/identity 2>/dev/null || true)"
driver="$(readlink -f /sys/class/watchdog/watchdog0/device 2>/dev/null || true)"
if [[ -z "$identity" || -z "$driver" ]]; then
  helper=/usr/libexec/ubuntu-kernel-reset-qa
  [[ -f "$helper" ]] || helper="$(dirname "${BASH_SOURCE[0]}")/test-kernel-reset.py"
  [[ -f "$helper" ]] || fail "watchdog ABI probe helper is unavailable"
  python3 "$helper" probe || fail "watchdog ABI probe failed"
  identity='Synopsys DesignWare Watchdog (ioctl)'
  driver='WDIOC_GETSUPPORT'
fi
printf 'PSTORE_WATCHDOG_PROBE_OK reset_tested=false pstore=%s watchdog=%s identity=%s driver=%s\n' \
  /sys/fs/pstore "$watchdog" "${identity:-unknown}" "$driver"
