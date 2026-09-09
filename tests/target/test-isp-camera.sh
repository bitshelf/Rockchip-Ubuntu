#!/usr/bin/env bash
set -Eeuo pipefail

SENSOR_PATTERN="${ISP_SENSOR_PATTERN:-ov13855}"
FRAMES="${ISP_FRAMES:-30}"
WIDTH="${ISP_WIDTH:-640}"
HEIGHT="${ISP_HEIGHT:-480}"
OUTPUT="${ISP_OUTPUT:-/tmp/isp-camera-qa.nv12}"
die() { echo "FAIL: $*" >&2; exit 1; }

for tool in journalctl od sha256sum systemctl v4l2-ctl; do
    command -v "$tool" >/dev/null || die "missing command: $tool"
done
[[ "$FRAMES" =~ ^[1-9][0-9]*$ && "$WIDTH" =~ ^[1-9][0-9]*$ &&
   "$HEIGHT" =~ ^[1-9][0-9]*$ ]] || die "invalid capture dimensions or frame count"

sensor=""
mainpath=""
for name_file in /sys/class/video4linux/*/name; do
    name="$(<"$name_file")"
    case "$name" in
        *"$SENSOR_PATTERN"*) sensor="${name_file%/name}" ;;
        rkisp_mainpath) mainpath="/dev/$(basename "${name_file%/name}")" ;;
    esac
done
[[ -n "$sensor" ]] || die "sensor not present: $SENSOR_PATTERN"
[[ -c "$mainpath" ]] || die "rkisp mainpath not present"
sensor_node="/dev/$(basename "$sensor")"
[[ -c "$sensor_node" ]] || die "sensor subdev is not present"
test_pattern="$(v4l2-ctl -d "$sensor_node" --get-ctrl=test_pattern 2>/dev/null || true)"
grep -Eq 'test_pattern:[[:space:]]+0([[:space:]]|$)' <<<"$test_pattern" ||
    die "sensor test pattern must be disabled for optical capture"
iq="$(find /etc/iqfiles -maxdepth 1 -type f -name "${SENSOR_PATTERN}*.json" -print -quit)"
[[ -s "$iq" ]] || die "sensor IQ JSON not installed"

systemctl restart rkaiq_3A.service
sleep 2
systemctl is-active --quiet rkaiq_3A.service || die "rkaiq 3A service is not active"
invocation="$(systemctl show -p InvocationID --value rkaiq_3A.service)"
[[ -n "$invocation" ]] || die "rkaiq service invocation is unavailable"
capture_log="$(mktemp "${ISP_TEST_TMP_ROOT:-/run}/isp-camera-qa.XXXXXX.log")"
trap 'rm -f -- "$capture_log"' EXIT
timeout 60 v4l2-ctl -d "$mainpath" \
    --set-fmt-video="width=$WIDTH,height=$HEIGHT,pixelformat=NV12" \
    --stream-mmap=4 --stream-skip=5 --stream-count="$FRAMES" \
    --stream-to="$OUTPUT" --verbose >"$capture_log" 2>&1 || {
        cat "$capture_log" >&2
        die "rkisp frame capture failed"
    }

frame_bytes=$((WIDTH * HEIGHT * 3 / 2))
expected_bytes=$((frame_bytes * FRAMES))
actual_bytes="$(stat -c %s "$OUTPUT")"
[[ "$actual_bytes" -eq "$expected_bytes" ]] ||
    die "capture size is $actual_bytes, expected $expected_bytes"
sequence_count="$(grep -c 'cap dqbuf:' "$capture_log" || true)"
[[ "$sequence_count" -ge "$FRAMES" ]] ||
    die "captured only $sequence_count frame sequences"
unique_bytes="$(od -An -N 1048576 -v -tu1 "$OUTPUT" | tr ' ' '\n' |
    sed '/^$/d' | sort -nu | wc -l)"
(( unique_bytes >= 16 )) || die "captured image has insufficient pixel variation"
log="$(journalctl -b "_SYSTEMD_INVOCATION_ID=$invocation" --no-pager)"
if grep -Eq '(AEC|AWB|ANALYZER):E:' <<<"$log"; then
    printf '%s\n' "$log" >&2
    die "rkaiq AE/AWB initialization or processing failed"
fi
grep -Fq 'rkisp_init engine succeed' <<<"$log" || die "rkaiq did not start the rkisp engine"
sha="$(sha256sum "$OUTPUT" | awk '{print $1}')"
printf 'RKAIQ_OK sensor=%s iq=%s\n' "$SENSOR_PATTERN" "$(basename "$iq")"
printf 'RKISP_FRAME_OK node=%s frames=%s bytes=%s unique_bytes=%s sha256=%s\n' \
    "$mainpath" "$FRAMES" "$actual_bytes" "$unique_bytes" "$sha"
printf 'ISP_CAMERA_OK sensor=%s format=NV12 size=%sx%s\n' \
    "$SENSOR_PATTERN" "$WIDTH" "$HEIGHT"
