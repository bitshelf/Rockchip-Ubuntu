#!/usr/bin/env bash
set -Eeuo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }
command -v v4l2-ctl >/dev/null || die "v4l2-ctl is not installed"
plugin=/usr/lib/aarch64-linux-gnu/libv4l/plugins/libv4l-rkmpp.so
[[ -s "$plugin" ]] || die "libv4l-rkmpp plugin is missing"
[[ "$(cat /dev/video-dec0 2>/dev/null)" == dec &&
   "$(cat /dev/video-enc0 2>/dev/null)" == enc ]] ||
    die "libv4l-rkmpp virtual endpoints are missing"

work="$(mktemp -d "${V4L2_TEST_TMP_ROOT:-/run}/v4l2-qa.XXXXXX")"
trap 'rm -rf -- "$work"' EXIT
v4l2-ctl --list-devices
v4l2-ctl --wrapper --device /dev/video-dec0 --all >"$work/decoder.log"
grep -Eq 'Video (Memory-to-Memory|M2M|Output)' "$work/decoder.log" ||
    die "libv4l-rkmpp decoder did not expose V4L2 capabilities"
echo "V4L2_RKMPP_OK device=/dev/video-dec0"

capture_device="${V4L2_CAPTURE_DEVICE:-}"
if [[ -n "$capture_device" ]]; then
    [[ -c "$capture_device" ]] || die "capture device is not a character device: $capture_device"
    output="$work/capture.raw"
    timeout 60 v4l2-ctl --device "$capture_device" --stream-mmap=4 \
        --stream-count="${V4L2_FRAME_COUNT:-30}" --stream-to="$output"
    [[ -s "$output" ]] || die "V4L2 capture produced no data"
    echo "V4L2_CAPTURE_OK device=$capture_device bytes=$(stat -c %s "$output")"
else
    echo "V4L2_ENUMERATION_OK capture=not-requested"
fi
