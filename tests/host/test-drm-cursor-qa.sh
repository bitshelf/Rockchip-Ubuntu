#!/usr/bin/env bash
set -Eeuo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/bin"; touch "$tmp/card"
cat >"$tmp/bin/modetest" <<'MOCK'
#!/bin/sh
case "$5" in
-p) printf '  8 type:\n    flags: immutable enum\n    enums: Overlay=0 Primary=1 Cursor=2\n    value: %s\n' "$CURSOR_TYPE" ;;
-c) printf 'id encoder status name\n42 43 %s HDMI-A-1\n' "$CONNECTOR_STATE" ;;
esac
MOCK
chmod +x "$tmp/bin/modetest"
export PATH="$tmp/bin:$PATH" DRM_BUSID=display-subsystem CURSOR_TYPE=2 CONNECTOR_STATE=connected
"$root/tests/target/test-drm-cursor.sh"
if CURSOR_TYPE=1 "$root/tests/target/test-drm-cursor.sh" >/dev/null 2>&1; then
    echo 'FAIL: enum advertised by a primary plane passed' >&2; exit 1
fi
if CONNECTOR_STATE=disconnected "$root/tests/target/test-drm-cursor.sh" >/dev/null 2>&1; then
    echo 'FAIL: disconnected connector passed' >&2; exit 1
fi
echo 'DRM cursor capability false-positive regression checks passed'
