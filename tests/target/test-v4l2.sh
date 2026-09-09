#!/usr/bin/env bash
set -Eeuo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }
command -v v4l2-ctl >/dev/null || die "v4l2-ctl is not installed"
plugin=/usr/lib/aarch64-linux-gnu/libv4l/plugins/libv4l-rkmpp.so
[[ -s "$plugin" ]] || die "libv4l-rkmpp plugin is missing"
[[ "$(cat /dev/video-dec0 2>/dev/null)" == dec &&
   "$(cat /dev/video-enc0 2>/dev/null)" == enc ]] ||
    die "libv4l-rkmpp virtual endpoints are missing"

v4l2-ctl --list-devices
v4l2-ctl --wrapper --device /dev/video-dec0 --all >/tmp/v4l2-rkmpp-decoder.log
grep -Eq 'Video (Memory-to-Memory|M2M|Output)' /tmp/v4l2-rkmpp-decoder.log ||
    die "libv4l-rkmpp decoder did not expose V4L2 capabilities"
echo "V4L2_RKMPP_OK device=/dev/video-dec0"

capture_device="${V4L2_CAPTURE_DEVICE:-}"
if [[ -z "$capture_device" ]]; then
    for name_file in /sys/class/video4linux/video*/name; do
        [[ -f "$name_file" ]] || continue
        case "$(<"$name_file")" in
            *mainpath*|*selfpath*) capture_device="/dev/$(basename "${name_file%/name}")"; break ;;
        esac
    done
fi
if [[ -n "$capture_device" ]]; then
    [[ -c "$capture_device" ]] || die "capture device is not a character device: $capture_device"
    output="$(mktemp)"
    trap 'rm -f -- "$output" /tmp/v4l2-rkmpp-decoder.log' EXIT
    v4l2-ctl --device "$capture_device" --stream-mmap=4 \
        --stream-count="${V4L2_FRAME_COUNT:-30}" --stream-to="$output"
    [[ -s "$output" ]] || die "V4L2 capture produced no data"
    echo "V4L2_CAPTURE_OK device=$capture_device bytes=$(stat -c %s "$output")"
else
    echo "V4L2_ENUMERATION_OK capture=not-present"
fi
