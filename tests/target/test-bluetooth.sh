#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C
fail() { echo "FAIL: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null || fail "missing command: $1"; }
mac="${BLUETOOTH_TEST_MAC:-}"
[[ "$mac" =~ ^([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}$ ]] || fail 'set a valid BLUETOOTH_TEST_MAC'
mac="${mac^^}"
profile="${BLUETOOTH_TEST_PROFILE:-none}"
case "$profile" in audio|hid|none) ;; *) fail 'profile must be audio, hid or none' ;; esac
need bluetoothctl; need systemctl
systemctl is-active --quiet bluetooth || fail 'bluetooth.service is inactive'
wait_property() {
    local key="$1" value="$2" i
    for ((i=0;i<15;i++)); do
        if bluetoothctl info "$mac" | grep -Eq "^[[:space:]]*$key: $value$"; then return 0; fi
        sleep 1
    done
    fail "$mac did not reach $key: $value"
}
bluetoothctl power on
if ! bluetoothctl info "$mac" | grep -Eq '^[[:space:]]*Paired: yes$'; then
    [[ -t 0 ]] || fail 'pair interactively in Blueman or a persistent bluetoothctl agent first'
    printf 'In bluetoothctl: default-agent; scan on; pair %s; scan off; quit. Confirm the peripheral passkey.\n' "$mac"
    bluetoothctl --agent KeyboardDisplay
fi
wait_property Paired yes
bluetoothctl trust "$mac"
wait_property Trusted yes
bluetoothctl connect "$mac"
wait_property Connected yes
bluetoothctl disconnect "$mac"
wait_property Connected no
bluetoothctl connect "$mac"
wait_property Connected yes
bluetoothctl info "$mac"
echo "BLUETOOTH_RECONNECT_OK mac=$mac (pairing may predate this run)"
case "$profile" in
    audio)
        need pw-dump; need pw-play; need python3
        [[ -f "${BLUETOOTH_TEST_WAV:-}" ]] || fail 'set BLUETOOTH_TEST_WAV to a known audible WAV'
        [[ -t 0 ]] || fail 'run in the GNOME user terminal for listening confirmation'
        node="$(pw-dump | python3 -c '
import json,sys
mac=sys.argv[1].replace(":","_")
nodes=[x.get("info",{}).get("props",{}) for x in json.load(sys.stdin) if x.get("type")=="PipeWire:Interface:Node"]
names=[p["node.name"] for p in nodes if p.get("media.class")=="Audio/Sink" and p.get("node.name","").upper().startswith("BLUEZ_OUTPUT."+mac+".")]
if len(names)!=1: sys.exit("Expected exactly one sink for target MAC, got %s" % names)
print(names[0])' "$mac")" || fail 'target Bluetooth sink missing or ambiguous'
        pw-play --target="$node" "$BLUETOOTH_TEST_WAV"
        read -r -p 'Did the selected Bluetooth peripheral play the expected audio clearly? Type yes: ' heard
        [[ "$heard" == yes ]] || fail 'audible playback not confirmed'
        echo "BLUETOOTH_AUDIO_PLAYBACK_OK mac=$mac node=$node"
        ;;
    hid)
        need evtest; need timeout
        events=()
        for path in /sys/class/input/event*/device/uniq; do
            [[ -r "$path" ]] || continue
            read -r uniq <"$path" || continue
            [[ "${uniq^^}" == "$mac" ]] || continue
            event="${path%/device/uniq}"; events+=("/dev/input/${event##*/}")
        done
        ((${#events[@]})) || fail 'no input event device has the target Bluetooth MAC'
        tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
        echo 'Press a key or move the Bluetooth mouse during each 15-second capture.'
        passed=no
        for event in "${events[@]}"; do
            rc=0
            timeout 15 evtest "$event" >"$tmp/events" 2>&1 || rc=$?
            cat "$tmp/events"
            [[ "$rc" == 0 || "$rc" == 124 ]] || fail "cannot read $event"
            if grep -Eq '^Event: time .*type (1 \(EV_KEY\)|2 \(EV_REL\)|3 \(EV_ABS\))' "$tmp/events"; then passed=yes; break; fi
        done
        [[ "$passed" == yes ]] || fail 'no real target HID input received'
        echo "BLUETOOTH_HID_INPUT_OK mac=$mac event=$event"
        ;;
esac
