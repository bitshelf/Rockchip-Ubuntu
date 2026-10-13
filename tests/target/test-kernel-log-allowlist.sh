#!/usr/bin/env bash
set -Eeuo pipefail
fail() { echo "FAIL: $*" >&2; exit 1; }
allowlist="${KERNEL_ERROR_ALLOWLIST:-/usr/share/ubuntu-hardware-qa/rk3576-kernel-errors.allow}"
[[ -s "$allowlist" ]] || allowlist=config/kernel/rk3576-kernel-errors.allow
[[ -s "$allowlist" ]] || fail "missing kernel error allowlist: $allowlist"
errors="$(dmesg --level=emerg,alert,crit,err)" || fail "cannot read kernel log"
normalized="$(sed -E 's/^\[[^]]+\][[:space:]]*//; s/^[[:space:]]+//' <<<"$errors" | sed '/^$/d')"
if grep -Fxq 'rockchip-vop2 27d00000.vop: failed to init opp info' <<<"$normalized"; then
  grep -Fq 'rockchip-vop2 27d00000.vop: Unsupported VOP aclk dvfs' <<<"$(dmesg)" ||
    fail 'VOP OPP failure has no confirmed fixed-clock fallback'
  echo 'VOP_FIXED_CLOCK_FALLBACK_CONFIRMED'
fi
if grep -Fxq 'rx8025 3-0032: hctosys: unable to read the hardware clock' <<<"$normalized"; then
  [[ "$(timedatectl show -p NTPSynchronized --value)" == yes ]] ||
    fail 'invalid cold RTC has no synchronized system clock'
  python3 - <<'PY'
import datetime, time
from pathlib import Path
rtc = Path('/sys/class/rtc/rtc0')
date = (rtc/'date').read_text().strip()
clock = (rtc/'time').read_text().strip()
stamp = datetime.datetime.fromisoformat(date+'T'+clock).replace(tzinfo=datetime.timezone.utc)
offset = abs(stamp.timestamp()-time.time())
if offset > 60:
    raise SystemExit('RTC has not recovered after clock synchronization')
print(f'RTC_POST_SYNC_TIME_OK offset_seconds={offset:.3f}')
PY
fi
if grep -Fxq 'tpm tpm0: A TPM error (256) occurred attempting the self test' <<<"$normalized"; then
  # TPM2_RC_INITIALIZE is handled by tpm2_auto_startup. Require actual
  # post-startup command success before accepting that exact boot message.
  timeout 10 python3 - <<'PY'
import os, struct
fd = os.open('/dev/tpmrm0', os.O_RDWR)
try:
    request = struct.pack('>HIIH', 0x8001, 12, 0x017b, 16)
    if os.write(fd, request) != len(request):
        raise SystemExit('TPM request incomplete')
    reply = os.read(fd, 4096)
    if len(reply) != 28 or struct.unpack('>HIIH', reply[:12]) != (0x8001, 28, 0, 16):
        raise SystemExit('TPM did not recover after automatic startup')
finally:
    os.close(fd)
print('TPM_POST_STARTUP_GETRANDOM_OK bytes=16')
PY
fi
patterns="$(mktemp)"; trap 'rm -f "$patterns"' EXIT
grep -Ev '^[[:space:]]*(#|$)' "$allowlist" >"$patterns" || fail "empty allowlist"
while IFS= read -r pattern; do
  [[ "$pattern" == ^* && "$pattern" == *'$' ]] || fail "allowlist expression must be anchored: $pattern"
done <"$patterns"
unexpected="$(grep -Ev -f "$patterns" <<<"$normalized" || true)"
[[ -z "$unexpected" ]] || { printf '%s\n' "$unexpected" >&2; fail "kernel log contains non-allowlisted errors"; }
echo "KERNEL_LOG_ALLOWLIST_OK"
