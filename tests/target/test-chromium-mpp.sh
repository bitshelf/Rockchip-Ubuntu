#!/usr/bin/env bash
set -Eeuo pipefail
fail() { echo "FAIL: $*" >&2; exit 1; }
[[ "${CHROMIUM_MPP_REAL:-0}" == 1 ]] || fail "set CHROMIUM_MPP_REAL=1 for real video QA"
for t in chromium gst-launch-1.0 python3 snap timeout; do command -v "$t" >/dev/null || fail "missing $t"; done
version="$(chromium --version)"
major="$(sed -n 's/.* \([0-9][0-9]*\)\..*/\1/p' <<<"$version")"
[[ "$major" =~ ^[0-9]+$ && "$major" -ge 150 ]] || fail "Chromium stable is stale: $version"
snap_record="$(snap list chromium 2>/dev/null | awk 'NR == 2 {print $1 "\t" $2 "\t" $3 "\t" $4 "\t" $5 "\t" $6}')"
[[ -n "$snap_record" ]] || fail "Chromium must be installed from the current stable arm64 snap"
[[ -n "${WAYLAND_DISPLAY:-}" && -n "${XDG_RUNTIME_DIR:-}" ]] || fail "run inside the GNOME Wayland session"
test -e /dev/video-dec0 || fail "missing /dev/video-dec0"
test -s /usr/lib/aarch64-linux-gnu/libv4l/plugins/libv4l-rkmpp.so || fail "missing libv4l-rkmpp plugin"
artifact_root="${QA_ARTIFACT_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/ubuntu-hardware-qa}"
work="$artifact_root/chromium-mpp-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$work/profile"
timeout 120 gst-launch-1.0 -q videotestsrc num-buffers=120 pattern=ball ! video/x-raw,width=1280,height=720,framerate=30/1 ! mpph264enc ! h264parse ! qtmux ! filesink location="$work/test.mp4" || fail "could not create test video"
cat >"$work/player.html" <<'EOF'
<!doctype html><meta charset="utf-8"><title>RK3576 Chromium MPP QA</title>
<video id="qa-video" autoplay muted loop controls width="1280" height="720" src="test.mp4"></video>
<script>window.qa_video_play = document.querySelector('video').play();</script>
EOF
before="$(awk '/rkvdec/ {print $2; exit}' /proc/interrupts)"; before="${before:-0}"
debug_port="${CHROMIUM_MPP_DEBUG_PORT:-9222}"
chromium --no-first-run --disable-gpu-sandbox --autoplay-policy=no-user-gesture-required \
    --enable-logging=stderr --v=1 --user-data-dir="$work/profile" \
    --remote-debugging-address=127.0.0.1 --remote-debugging-port="$debug_port" \
    '--remote-allow-origins=*' chrome://media-internals "file://$work/player.html" \
    >"$work/chromium.log" 2>&1 & pid=$!
sleep "${CHROMIUM_MPP_PLAY_SECONDS:-8}"
held="$(for p in $(pgrep -f 'chrom(e|ium)' || true); do readlink /proc/$p/fd/* 2>/dev/null; done | grep -E '/dev/video-dec0|/dev/mpp_service' | head -1 || true)"
# Capture the actual chrome://media-internals surface through DevTools.  The
# recursive walk includes Chromium WebUI shadow roots; clicking the player
# entries first exposes the decoder properties in the details pane.
python3 - "$debug_port" "$work" <<'PY' || fail "could not capture chrome://media-internals"
import base64, json, pathlib, sys, time, urllib.request
import websocket

port, out = sys.argv[1], pathlib.Path(sys.argv[2])
targets = json.load(urllib.request.urlopen(f"http://127.0.0.1:{port}/json/list", timeout=10))
target = next((t for t in targets if t.get("url", "").startswith("chrome://media-internals")), None)
if not target:
    raise SystemExit("media-internals DevTools target not found")
ws = websocket.create_connection(target["webSocketDebuggerUrl"], timeout=10)
seq = 0
def call(method, params=None):
    global seq
    seq += 1
    ws.send(json.dumps({"id": seq, "method": method, "params": params or {}}))
    while True:
        reply = json.loads(ws.recv())
        if reply.get("id") == seq:
            return reply
call("Runtime.enable")
click = r'''(() => {
  const visit = root => {
    for (const el of root.querySelectorAll('*')) {
      if (el.shadowRoot) visit(el.shadowRoot);
      const text = (el.innerText || el.textContent || '').trim();
      if (/test\.mp4|qa-video/i.test(text) && typeof el.click === 'function') el.click();
    }
  }; visit(document); return true;
})()'''
call("Runtime.evaluate", {"expression": click, "returnByValue": True})
time.sleep(2)
dump = r'''(() => {
  const lines = [];
  const visit = root => {
    for (const el of root.querySelectorAll('*')) {
      if (el.shadowRoot) visit(el.shadowRoot);
      if (el.children.length === 0) {
        const text = (el.innerText || el.textContent || '').trim();
        if (text) lines.push(text);
      }
    }
  }; visit(document);
  return lines.join('\n');
})()'''
reply = call("Runtime.evaluate", {"expression": dump, "returnByValue": True})
value = reply.get("result", {}).get("result", {}).get("value", "")
(out / "media-internals.txt").write_text(value, encoding="utf-8")
shot = call("Page.captureScreenshot", {"format": "png", "captureBeyondViewport": True})
data = shot.get("result", {}).get("data")
if data:
    (out / "media-internals.png").write_bytes(base64.b64decode(data))
ws.close()
PY
kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
after="$(awk '/rkvdec/ {print $2; exit}' /proc/interrupts)"; after="${after:-0}"
(( after > before )) || fail "rkvdec IRQ did not advance ($before -> $after)"
[[ -n "$held" ]] || fail "Chromium did not hold V4L2/MPP decoder device"
grep -Eiq 'V4L2VideoDecoder|V4L2[^[:space:]]*Decoder' "$work/media-internals.txt" || \
    fail "media-internals did not report V4L2VideoDecoder (evidence: $work)"
printf 'chromium_version=%s\nsnap=%s\nrkvdec_irqs=%s->%s\ndevice=%s\nvideo=%s\n' \
    "$version" "$snap_record" "$before" "$after" "$held" "$work/test.mp4" >"$work/result.txt"
echo "CHROMIUM_MPP_REAL_VIDEO_OK version=$version snap=$snap_record rkvdec_irqs=$before->$after device=$held media_internals=$work/media-internals.txt"
