#!/usr/bin/env bash
set -Eeuo pipefail
fail() { echo "FAIL: $*" >&2; exit 1; }
[[ -r /sys/kernel/realtime && "$(cat /sys/kernel/realtime)" == 1 ]] || fail "running kernel does not report PREEMPT_RT"
grep -q PREEMPT_RT /proc/version || fail "kernel build does not identify PREEMPT_RT"
config=/proc/config.gz
[[ -r "$config" ]] || config="/boot/config-$(uname -r)"
[[ -r "$config" ]] || fail "running kernel configuration is unavailable"
if [[ "$config" == *.gz ]]; then config_text="$(zcat "$config")"; else config_text="$(cat "$config")"; fi
for option in CONFIG_PREEMPT_RT CONFIG_HZ_1000; do
  grep -Fxq "$option=y" <<<"$config_text" || fail "missing kernel option $option"
done
command -v cyclictest >/dev/null || fail "cyclictest is missing (install rt-tests)"
cpu="${RT_TEST_CPU:-0}"
[[ "$cpu" =~ ^[0-9]+$ ]] || fail "RT_TEST_CPU must be a CPU number"
printf 'kernel=%s cpu=%s seconds=%s max_threshold_us=50\n' "$(uname -r)" "$cpu" "${RT_TEST_SECONDS:-60}"
output="$(cyclictest -m -a "$cpu" -c 0 -p 99 -t 1 -i 500 -D "${RT_TEST_SECONDS:-60}" -h 50 -q 2>&1)" || fail "cyclictest execution failed"
printf '%s\n' "$output"
maximum="$(awk '/^# Max Latencies:/ {print $4}' <<<"$output")"
overflows="$(awk '/^# Histogram Overflows:/ {print $4}' <<<"$output")"
[[ "$maximum" =~ ^[0-9]+$ && "$overflows" =~ ^[0-9]+$ ]] || fail "cannot parse cyclictest result"
(( 10#$overflows == 0 && 10#$maximum < 50 )) || fail "cyclictest max/overflow threshold exceeded"
printf 'CYCLICTEST_RT_OK cpu=%s max_us=%s overflows=%s seconds=%s\n' "$cpu" "$maximum" "$overflows" "${RT_TEST_SECONDS:-60}"
