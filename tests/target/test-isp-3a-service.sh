#!/usr/bin/env bash
# Service bring-up only; this does not certify 3A algorithms or image quality.
set -Eeuo pipefail
fail() { echo "FAIL: $*" >&2; exit 1; }
sensor_pattern="${ISP_SENSOR_PATTERN:-ov13855}"
[[ "$EUID" == 0 ]] || fail 'run as root'
sensor=
for name_file in /sys/class/video4linux/v4l-subdev*/name; do
    [[ -r "$name_file" ]] || continue
    name="$(<"$name_file")"
    [[ "$name" != *"$sensor_pattern"* ]] || sensor="$name"
done
[[ -n "$sensor" ]] || fail "sensor subdev absent: $sensor_pattern"
systemctl is-enabled --quiet rkaiq_3A.service || fail '3A service is disabled'
systemctl is-active --quiet rkaiq_3A.service || fail '3A service is inactive'
pid="$(systemctl show -p MainPID --value rkaiq_3A.service)"
[[ "$pid" =~ ^[1-9][0-9]*$ && -e /proc/$pid/exe ]] || fail '3A process is absent'
invocation="$(systemctl show -p InvocationID --value rkaiq_3A.service)"
log="$(journalctl -b "_SYSTEMD_INVOCATION_ID=$invocation" --no-pager)"
grep -Fq 'rk_aiq_uapi2_sysctl_init success' <<<"$log" || fail 'RKAIQ init did not complete'
grep -Fq 'rk_aiq_uapi2_sysctl_prepare success' <<<"$log" || fail 'RKAIQ prepare did not complete'
[[ "$log" == *"iq:/etc/iqfiles/"* ]] || fail 'IQ loading was not recorded'
sleep "${ISP_3A_OBSERVE_SECONDS:-30}"
systemctl is-active --quiet rkaiq_3A.service || fail '3A service stopped during observation'
[[ "$(systemctl show -p MainPID --value rkaiq_3A.service)" == "$pid" ]] || fail '3A process restarted'
log="$(journalctl -b "_SYSTEMD_INVOCATION_ID=$invocation" --no-pager)"
if grep -Eq 'Thread\([^)]*\) create fail|Main process exited|signal=SEGV' <<<"$log"; then
    fail '3A service has a thread or process failure'
fi
printf 'ISP_3A_SERVICE_OK sensor=%s pid=%s observation_seconds=%s\n' "$sensor" "$pid" "${ISP_3A_OBSERVE_SECONDS:-30}"
if grep -Eq '(AEC|AWB|ANALYZER):E:' <<<"$log"; then
    echo 'ISP_3A_ALGORITHM_QA=not_validated:IQ_schema_errors_present'
fi
