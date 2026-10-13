#!/usr/bin/env bash
set -Eeuo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/bin"
cat >"$tmp/bin/bluetoothctl" <<'MOCK'
#!/usr/bin/env bash
case "$1" in
 info) printf 'Paired: yes\nTrusted: yes\nConnected: %s\n' "$(cat "$BT_STATE" 2>/dev/null || echo no)" ;;
 connect) echo yes >"$BT_STATE" ;;
 disconnect) echo no >"$BT_STATE" ;;
esac
MOCK
printf '#!/bin/sh\nexit 0\n' >"$tmp/bin/systemctl"
chmod +x "$tmp/bin/"*
export PATH="$tmp/bin:$PATH" BT_STATE="$tmp/state" BLUETOOTH_TEST_MAC=AA:BB:CC:DD:EE:FF
BLUETOOTH_TEST_PROFILE=none "$root/tests/target/test-bluetooth.sh" >"$tmp/result"
grep -q BLUETOOTH_RECONNECT_OK "$tmp/result"
if BLUETOOTH_TEST_MAC=invalid "$root/tests/target/test-bluetooth.sh" >/dev/null 2>&1; then exit 1; fi
if BLUETOOTH_TEST_PROFILE=invalid "$root/tests/target/test-bluetooth.sh" >/dev/null 2>&1; then exit 1; fi
# A host's unrelated keyboard must not satisfy Bluetooth HID QA.
printf '#!/bin/sh\nexit 0\n' >"$tmp/bin/evtest"; chmod +x "$tmp/bin/evtest"
if BLUETOOTH_TEST_PROFILE=hid "$root/tests/target/test-bluetooth.sh" >"$tmp/hid" 2>&1; then
    echo 'Unrelated input incorrectly passed HID QA' >&2; exit 1
fi
grep -q 'no input event device has the target Bluetooth MAC' "$tmp/hid"
printf 'blueman 1\n' >"$tmp/manifest"
if "$root/scripts/check-desktop-manifest.sh" server "$tmp/manifest" >/dev/null 2>&1; then exit 1; fi
echo 'Bluetooth reconnect and false-positive regression checks passed'
