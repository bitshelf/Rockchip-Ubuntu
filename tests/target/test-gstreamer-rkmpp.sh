#!/usr/bin/env bash
set -Eeuo pipefail

frames="${GSTREAMER_RKMPP_FRAMES:-100}"
[[ "$frames" =~ ^[1-9][0-9]*$ ]] || {
    echo "ERROR: GSTREAMER_RKMPP_FRAMES must be a positive integer" >&2
    exit 2
}

for tool in gst-inspect-1.0 gst-launch-1.0 timeout; do
    command -v "$tool" >/dev/null || {
        echo "ERROR: missing GStreamer tool: $tool" >&2
        exit 1
    }
done
[[ -c /dev/mpp_service ]] || {
    echo "ERROR: /dev/mpp_service is unavailable" >&2
    exit 1
}
for element in mpph264enc mppvideodec h264parse; do
    gst-inspect-1.0 "$element" >/dev/null || {
        echo "ERROR: missing GStreamer element: $element" >&2
        exit 1
    }
done

runtime_dir="${XDG_RUNTIME_DIR:-/tmp}"
[[ -d "$runtime_dir" && -w "$runtime_dir" ]] || {
    echo "ERROR: runtime directory is not writable: $runtime_dir" >&2
    exit 1
}
log="$(mktemp "$runtime_dir/gstreamer-rkmpp.XXXXXX.log")"
trap 'rm -f -- "$log"' EXIT
if ! timeout 120 gst-launch-1.0 -e -v \
        videotestsrc num-buffers="$frames" is-live=false \
        ! video/x-raw,format=NV12,width=640,height=360,framerate=30/1 \
        ! mpph264enc \
        ! h264parse \
        ! mppvideodec \
        ! fakesink sync=false 2>&1 | tee "$log"; then
    echo "ERROR: Rockchip GStreamer hardware pipeline failed" >&2
    exit 1
fi
grep -Fq 'Got EOS from element' "$log" || {
    echo "ERROR: hardware pipeline did not reach EOS" >&2
    exit 1
}
grep -Eiq 'error|failed|not-negotiated' "$log" && {
    echo "ERROR: hardware pipeline log contains a failure" >&2
    exit 1
}

printf 'GSTREAMER_RKMPP_OK frames=%s encoder=mpph264enc decoder=mppvideodec\n' "$frames"
