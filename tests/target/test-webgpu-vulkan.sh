#!/usr/bin/env bash
set -Eeuo pipefail
fail() { echo "FAIL: $*" >&2; exit 1; }
[[ "${WEBGPU_REAL:-0}" == 1 ]] || fail 'set WEBGPU_REAL=1 for hardware WebGPU QA'
for t in chromium python3; do command -v "$t" >/dev/null || fail "missing $t"; done
[[ "$EUID" != 0 ]] || fail 'run as an unprivileged user'
kernel_config="/boot/config-$(uname -r)"
if [[ -r /proc/config.gz ]]; then
    kernel_options="$(zcat /proc/config.gz)"
elif [[ -r "$kernel_config" ]]; then
    kernel_options="$(cat "$kernel_config")"
else
    fail 'running kernel configuration is unavailable'
fi
grep -Fxq 'CONFIG_ARM64_VA_BITS_48=y' <<<"$kernel_options" ||
    fail 'WebGPU shared ArrayBuffer qualification requires the 48-bit ARM64 VA kernel profile'
display_args=(--ozone-platform=wayland)
if [[ "${CHROMIUM_QA_HEADLESS:-0}" == 1 ]]; then
    display_args=(--headless=new --ozone-platform=headless --window-size=1280,720)
elif [[ "${CHROMIUM_QA_SESSION:-wayland}" == x11 ]]; then
    [[ -n "${DISPLAY:-}" ]] || fail 'Xserver DISPLAY is missing'
    display_args=(--ozone-platform=x11)
else
    [[ "${CHROMIUM_QA_SESSION:-wayland}" == wayland ]] || fail 'invalid CHROMIUM_QA_SESSION'
    [[ -n "${WAYLAND_DISPLAY:-}" && -n "${XDG_RUNTIME_DIR:-}" ]] || fail 'run as the GNOME Wayland user, or explicitly set CHROMIUM_QA_HEADLESS=1'
fi
backend="${WEBGPU_BACKEND:-vulkan}"
case "$backend" in
    vulkan) backend_args=(--use-angle=vulkan --use-vulkan=native --use-webgpu-adapter=default); probe_query= ;;
    vulkan-readback) backend_args=(--use-angle=gl --gpu-sandbox-start-early --use-webgpu-adapter=default --disable-features=Vulkan --enable-features=WebGPUVulkanReadback --enable-webgpu-developer-features); probe_query= ;;
    gles-compat) backend_args=(--use-angle=gl --use-webgpu-adapter=opengles --enable-webgpu-developer-features --enable-features=WebGPUCompatibilityMode --disable-features=Vulkan); probe_query='?featureLevel=compatibility' ;;
    gles-policy)
        [[ "$(cat /etc/chromium/rockchip-webgpu-backend 2>/dev/null)" == gles-compat ]] || fail 'image GLES policy is missing'
        backend_args=(--enable-webgpu-developer-features)
        probe_query='?featureLevel=compatibility' ;;
    *) fail 'WEBGPU_BACKEND must be vulkan, vulkan-readback, gles-compat or gles-policy' ;;
esac
work="${QA_ARTIFACT_DIR:-$HOME/.local/share/ubuntu-hardware-qa}/webgpu-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$work/profile"
probe="${WEBGPU_PROBE_HTML:-/usr/share/ubuntu-hardware-qa/webgpu-render.html}"
[[ -s "$probe" ]] || fail 'WebGPU render probe missing'
cp "$probe" "$work/probe.html"
find /usr/share/vulkan/icd.d /etc/vulkan/icd.d -name '*.json' -print > "$work/icds.txt" 2>/dev/null || true
[[ -s "$work/icds.txt" ]] || fail 'Vulkan ICD missing'
port="${WEBGPU_DEBUG_PORT:-9223}"
chromium --no-first-run "${display_args[@]}" --enable-unsafe-webgpu \
    "${backend_args[@]}" --ignore-gpu-blocklist \
    --user-data-dir="$work/profile" --remote-debugging-address=127.0.0.1 \
    --remote-debugging-port="$port" '--remote-allow-origins=*' \
    "file://$work/probe.html$probe_query" > "$work/chromium.log" 2>&1 & pid=$!
trap 'kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true' EXIT
python3 - "$port" "$work" "$backend" <<'PY'
import base64, json, pathlib, re, sys, time, urllib.request
import websocket
port, out, backend = sys.argv[1], pathlib.Path(sys.argv[2]), sys.argv[3]
url = f'http://127.0.0.1:{port}'
deadline = time.monotonic() + 90
while True:
    try:
        targets = json.load(urllib.request.urlopen(url + '/json/list', timeout=3))
        page = next(t for t in targets if t.get('url', '').split('?', 1)[0].endswith('/probe.html'))
        break
    except (OSError, ValueError, StopIteration):
        if time.monotonic() >= deadline: raise SystemExit('DevTools probe unavailable')
        time.sleep(1)
class CDP:
    def __init__(self, target):
        self.ws = websocket.create_connection(target, timeout=10)
        self.seq = 0
    def call(self, method, params=None):
        self.seq += 1
        self.ws.send(json.dumps({'id':self.seq, 'method':method, 'params':params or {}}))
        while True:
            reply = json.loads(self.ws.recv())
            if reply.get('id') == self.seq:
                if 'error' in reply: raise RuntimeError(reply['error'])
                return reply.get('result', {})
    def evaluate(self, expression):
        result = self.call('Runtime.evaluate', {'expression':expression, 'returnByValue':True})
        if 'exceptionDetails' in result: raise RuntimeError(result['exceptionDetails'])
        return result.get('result', {}).get('value')
probe = CDP(page['webSocketDebuggerUrl'])
probe.call('Page.bringToFront')
while time.monotonic() < deadline:
    title = probe.evaluate('document.title') or ''
    if title.startswith('WEBGPU_RENDER_OK') or (title.startswith('WEBGPU_RENDER_') and title != 'WEBGPU_RENDER_PROBE'): break
    time.sleep(1)
result = probe.evaluate('window.webgpuResult || {}')
(out/'render.json').write_text(json.dumps({'title':title, 'result':result},indent=2)+'\n')
shot = probe.call('Page.captureScreenshot', {'format':'png'})
(out/'webgpu.png').write_bytes(base64.b64decode(shot['data']))
probe.ws.close()
version = json.load(urllib.request.urlopen(url+'/json/version',timeout=3))
browser = CDP(version['webSocketDebuggerUrl'])
gpu = browser.call('SystemInfo.getInfo')
(out/'gpu-info.json').write_text(json.dumps(gpu,indent=2)+'\n')
browser.ws.close()
request = urllib.request.Request(url+'/json/new?chrome://gpu', method='PUT')
gpu_page = CDP(json.load(urllib.request.urlopen(request,timeout=5))['webSocketDebuggerUrl'])
time.sleep(2)
text = gpu_page.evaluate("(() => {let s=[]; function walk(r){for(const e of r.querySelectorAll('*')){if(e.shadowRoot)walk(e.shadowRoot);if(!e.children.length)s.push(e.innerText||e.textContent||'')}}walk(document);return s.join('\\n')})()")
(out/'chrome-gpu.txt').write_text(text or '')
gpu_page.ws.close()
if not title.startswith('WEBGPU_RENDER_OK'): raise SystemExit(f'WebGPU probe failed: {title}')
if result.get('computeValuesChecked') != 256: raise SystemExit('WebGPU compute readback incomplete')
if not result.get('canvasSubmitted'): raise SystemExit('WebGPU canvas presentation was not exercised')
if backend in ('vulkan', 'vulkan-readback'):
    if result.get('featureLevel') != 'core' or not result.get('coreFeaturesAndLimits'): raise SystemExit('WebGPU core feature level was not verified')
elif result.get('featureLevel') != 'compatibility' or result.get('coreFeaturesAndLimits'): raise SystemExit('compatibility feature level was not verified')
adapter = result.get('adapter', {})
if not title.startswith('WEBGPU_RENDER_OK') or result.get('redPixels',0) <= 0: raise SystemExit('hardware WebGPU render/readback failed: '+title)
if adapter.get('fallback') or not re.search(r'arm|mali|13b5', str(adapter), re.I): raise SystemExit('not an ARM/Mali hardware adapter: '+str(adapter))
devices = gpu.get('gpu',{}).get('devices',[])
if not any(d.get('vendorId') == 0x13b5 or re.search(r'arm|mali',str(d),re.I) for d in devices): raise SystemExit('Chromium GPU device is not ARM/Mali')
if not gpu.get('gpu',{}).get('auxAttributes',{}).get('sandboxed'): raise SystemExit('GPU sandbox is disabled')
if gpu.get('gpu',{}).get('auxAttributes',{}).get('processCrashCount',0): raise SystemExit('GPU process crashed')
print(title)
print(('WEBGPU_VULKAN_HARDWARE_OK' if backend in ('vulkan', 'vulkan-readback') else 'WEBGPU_GLES_COMPAT_HARDWARE_OK')+' backend='+backend+' evidence='+str(out))
PY
