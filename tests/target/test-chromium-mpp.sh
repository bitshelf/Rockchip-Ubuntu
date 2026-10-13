#!/usr/bin/env bash
set -Eeuo pipefail
fail() { echo "FAIL: $*" >&2; exit 1; }
video_source="${CHROMIUM_MPP_VIDEO:-}"
[[ "$video_source" == /* && -f "$video_source" && -s "$video_source" ]] ||
    fail "CHROMIUM_MPP_VIDEO must name an existing absolute path to real H.264 MP4 footage"
for t in chromium python3 dpkg-query sha256sum; do command -v "$t" >/dev/null || fail "missing $t"; done
version="$(chromium --version)"
major="$(sed -n 's/.* \([0-9][0-9]*\)\..*/\1/p' <<<"$version")"
[[ "$major" =~ ^[0-9]+$ && "$major" -ge 150 ]] || fail "Chromium stable is stale: $version"
package_record="$(dpkg-query -W -f='${Package}\t${Version}\t${Architecture}\n' chromium)"
[[ "$package_record" == *$'\tarm64' ]] || fail "Chromium must be the RKMPP ARM64 DEB"
[[ "$EUID" != 0 ]] || fail "run as an unprivileged user"
display_args=(--ozone-platform=wayland)
if [[ "${CHROMIUM_QA_HEADLESS:-0}" == 1 ]]; then
    display_args=(--headless=new --ozone-platform=headless --window-size=1280,720)
else
    [[ -n "${WAYLAND_DISPLAY:-}" && -n "${XDG_RUNTIME_DIR:-}" ]] || fail "run inside the GNOME Wayland session, or explicitly set CHROMIUM_QA_HEADLESS=1"
fi
test -e /dev/video-dec0 || fail "missing /dev/video-dec0"
test -s /usr/lib/aarch64-linux-gnu/libv4l/plugins/libv4l-rkmpp.so || fail "missing libv4l-rkmpp plugin"
artifact_root="${QA_ARTIFACT_DIR:-$HOME/.local/share/ubuntu-hardware-qa}"
work="$artifact_root/chromium-mpp-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$work/profile"
cp -- "$video_source" "$work/real-video.mp4"
sha256sum "$work/real-video.mp4" >"$work/real-video.mp4.sha256"
cat >"$work/player.html" <<'EOF'
<!doctype html><meta charset="utf-8"><title>RK3576 Chromium MPP QA</title>
<video id="qa-video" muted loop controls width="1280" height="720" src="real-video.mp4"></video>
EOF
irq_count() {
    awk '/rkvdec/ {for (i=2; i<=NF && $i ~ /^[0-9]+$/; i++) total += $i} END {print total+0}' /proc/interrupts
}
before="$(irq_count)"
debug_port="${CHROMIUM_MPP_DEBUG_PORT:-9222}"
chromium --no-first-run "${display_args[@]}" \
    --enable-features=AcceleratedVideoDecoder,PreferV4L2VideoAcceleration \
    --autoplay-policy=no-user-gesture-required \
    --enable-logging=stderr --v=1 \
    --vmodule=video_decoder_pipeline=2,v4l2_video_decoder=2,v4l2_device=2 \
    --user-data-dir="$work/profile" \
    --remote-debugging-address=127.0.0.1 --remote-debugging-port="$debug_port" \
    '--remote-allow-origins=*' "file://$work/player.html" \
    >"$work/chromium.log" 2>&1 & pid=$!
trap 'kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true' EXIT
# Capture the actual chrome://media-internals surface through DevTools.  The
# recursive walk includes Chromium WebUI shadow roots; clicking the player
# entries first exposes the decoder properties in the details pane.
python3 - "$debug_port" "$work" "$pid" <<'PY' || fail "real video playback or media-internals capture failed (evidence: $work)"
import base64, hashlib, json, pathlib, sys, time, urllib.request
import websocket

port, out, browser_pid = sys.argv[1], pathlib.Path(sys.argv[2]), int(sys.argv[3])
deadline = time.monotonic() + 30
while True:
    try:
        targets = json.load(urllib.request.urlopen(f"http://127.0.0.1:{port}/json/list", timeout=3))
        break
    except (OSError, ValueError):
        if time.monotonic() >= deadline:
            raise SystemExit("Chromium DevTools did not become ready")
        time.sleep(1)
with pathlib.Path(f"/proc/{browser_pid}/exe").open("rb") as executable:
    binary_sha256 = hashlib.file_digest(executable, "sha256").hexdigest()
(out / "browser-executable.sha256").write_text(binary_sha256 + "\n", encoding="utf-8")
(out / "devtools-targets.json").write_text(json.dumps(targets, indent=2), encoding="utf-8")
player = next((t for t in targets if t.get("url", "").endswith("/player.html")), None)
if not player:
    raise SystemExit("real video player DevTools target not found")
target = next((t for t in targets if t.get("url", "").startswith("chrome://media-internals")), None)
if not target:
    request = urllib.request.Request(
        f"http://127.0.0.1:{port}/json/new?chrome://media-internals", method="PUT")
    target = json.load(urllib.request.urlopen(request, timeout=10))
if not target.get("url", "").startswith("chrome://media-internals"):
    raise SystemExit(f"media-internals target unavailable: {target.get('url')}")
time.sleep(2)
player_ws = websocket.create_connection(player["webSocketDebuggerUrl"], timeout=10)
player_ws.send(json.dumps({"id": 10, "method": "Page.bringToFront"}))
while json.loads(player_ws.recv()).get("id") != 10:
    pass
player_ws.send(json.dumps({"id": 1, "method": "Runtime.evaluate", "params": {"expression": "document.querySelector('video').play()"}}))
while json.loads(player_ws.recv()).get("id") != 1:
    pass
deadline = time.monotonic() + 45
quality = {}
while time.monotonic() < deadline:
    player_ws.send(json.dumps({"id": 2, "method": "Runtime.evaluate", "params": {
        "expression": "(() => {const v=document.querySelector('video'); const q=v.getVideoPlaybackQuality(); return {width:v.videoWidth,height:v.videoHeight,duration:v.duration,currentTime:v.currentTime,frames:q.totalVideoFrames,dropped:q.droppedVideoFrames,error:v.error?.message||''}})()",
        "returnByValue": True}}))
    while True:
        result = json.loads(player_ws.recv())
        if result.get("id") == 2:
            quality = result.get("result", {}).get("result", {}).get("value", {})
            break
    if quality.get("error"):
        raise SystemExit(f"video playback error: {quality['error']}")
    if quality.get("frames", 0) >= 60 and quality.get("currentTime", 0) >= 2:
        break
    time.sleep(1)
(out / "playback.json").write_text(json.dumps(quality, indent=2), encoding="utf-8")
if quality.get("frames", 0) < 60 or quality.get("width", 0) < 640 or quality.get("height", 0) < 360 or quality.get("duration", 0) < 10:
    raise SystemExit(f"real footage playback incomplete: {quality}")
player_ws.send(json.dumps({"id": 3, "method": "Page.captureScreenshot", "params": {"format": "png"}}))
while True:
    shot = json.loads(player_ws.recv())
    if shot.get("id") == 3:
        image = shot.get("result", {}).get("data")
        if not image:
            raise SystemExit("real-video screenshot unavailable")
        (out / "real-video.png").write_bytes(base64.b64decode(image))
        break
player_ws.close()
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
call("Page.bringToFront")
call("Runtime.enable")
dom = call("Runtime.evaluate", {"expression": "document.body.outerHTML", "returnByValue": True})
(out / "media-internals-dom.html").write_text(dom.get("result", {}).get("result", {}).get("value", ""), encoding="utf-8")
selection = call("Runtime.evaluate", {"expression": "(() => {const player=document.querySelector('#player-list .tree-item-header'); if (!player) return false; player.click(); return true})()", "returnByValue": True})
if not selection.get("result", {}).get("result", {}).get("value"):
    raise SystemExit("media-internals did not list the real-video player")
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
version = json.load(urllib.request.urlopen(f"http://127.0.0.1:{port}/json/version", timeout=3))
ws = websocket.create_connection(version["webSocketDebuggerUrl"], timeout=10)
gpu = call("SystemInfo.getInfo").get("result", {})
(out / "gpu-info.json").write_text(json.dumps(gpu, indent=2)+"\n")
ws.close()
attributes = gpu.get("gpu", {}).get("auxAttributes", {})
if not attributes.get("sandboxed") or attributes.get("processCrashCount", 0):
    raise SystemExit("GPU sandbox is inactive or the GPU process crashed")
children = {browser_pid}
while True:
    previous = len(children)
    for proc in pathlib.Path('/proc').iterdir():
        if not proc.name.isdecimal():
            continue
        try:
            stat = (proc / 'stat').read_text()
            parent = int(stat.rsplit(')', 1)[1].split()[1])
            if parent in children:
                children.add(int(proc.name))
        except (OSError, ValueError, IndexError):
            pass
    if len(children) == previous:
        break
held = []
for child in children:
    try:
        for fd in (pathlib.Path('/proc') / str(child) / 'fd').iterdir():
            path = fd.resolve(strict=False).as_posix()
            if path in ('/dev/video-dec0', '/dev/mpp_service'):
                held.append(f'{child}:{path}')
    except OSError:
        pass
(out / 'decoder-fds.txt').write_text('\n'.join(held) + '\n', encoding='utf-8')
PY
after="$(irq_count)"
printf 'chromium_version=%s\npackage=%s\nrkvdec_irqs=%s->%s\nvideo=%s\n' \
    "$version" "$package_record" "$before" "$after" "$video_source" >"$work/result.txt"
grep -A1 '^kVideoDecoderName$' "$work/media-internals.txt" | grep -Fq '"V4L2VideoDecoder"' || \
    fail "media-internals did not report V4L2VideoDecoder (evidence: $work)"
grep -A1 '^kIsPlatformVideoDecoder$' "$work/media-internals.txt" | grep -Fq 'true' || \
    fail "media-internals did not report platform video decoding (evidence: $work)"
grep -Eq '/dev/(video-dec0|mpp_service)' "$work/decoder-fds.txt" || \
    fail "Chromium did not open a V4L2/MPP decoder (evidence: $work)"
(( after > before )) || fail "rkvdec IRQ did not advance ($before -> $after; evidence: $work)"
echo "CHROMIUM_MPP_REAL_VIDEO_OK version=$version package=$package_record rkvdec_irqs=$before->$after evidence=$work"
