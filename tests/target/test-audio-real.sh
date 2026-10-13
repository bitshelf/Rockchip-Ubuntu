#!/usr/bin/env bash
set -Eeuo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }
command -v aplay >/dev/null || die "aplay is missing"
command -v arecord >/dev/null || die "arecord is missing"
command -v python3 >/dev/null || die "python3 is missing"

tmp="$(mktemp -d /run/ubuntu-audio-qa.XXXXXX)"
trap 'rm -rf "$tmp"' EXIT
aplay -l >"$tmp/aplay.txt" || die "no playback cards"
arecord -l >"$tmp/arecord.txt" || die "no capture cards"
play="${AUDIO_PLAYBACK_DEVICE:-}"
capture="${AUDIO_CAPTURE_DEVICE:-}"
[[ -n "$play" ]] || play="$(sed -n 's/^card \([0-9][0-9]*\):.*device \([0-9][0-9]*\):.*/\1,\2/p' "$tmp/aplay.txt" | head -n1)"
[[ -n "$capture" ]] || capture="$(sed -n 's/^card \([0-9][0-9]*\):.*device \([0-9][0-9]*\):.*/\1,\2/p' "$tmp/arecord.txt" | head -n1)"
[[ -n "$play" && -n "$capture" ]] || die "could not map ALSA playback/capture devices"
for device in "$play" "$capture"; do
    [[ "$device" =~ ^[0-9]+,[0-9]+$ ]] || die "ALSA device must be an enumerated card,device pair"
done
grep -Eq "^card ${play%,*}:.*device ${play#*,}:" "$tmp/aplay.txt" || die "playback device is absent"
grep -Eq "^card ${capture%,*}:.*device ${capture#*,}:" "$tmp/arecord.txt" || die "capture device is absent"
python3 - "$tmp/tone.wav" <<'PY'
import math, struct, sys, wave
with wave.open(sys.argv[1], 'wb') as f:
    f.setnchannels(2); f.setsampwidth(2); f.setframerate(48000)
    for i in range(48000):
        x=int(1200*math.sin(2*math.pi*440*i/48000))
        f.writeframesraw(struct.pack('<hh', x, x))
PY
aplay -q -D "plughw:$play" "$tmp/tone.wav" ||
    aplay -q -D "hw:$play" "$tmp/tone.wav" || die "real playback failed"
timeout 8 arecord -q -D "plughw:$capture" -f S16_LE -c 2 -r 48000 -d 2 "$tmp/capture.wav" ||
    timeout 8 arecord -q -D "hw:$capture" -f S16_LE -c 2 -r 48000 -d 2 "$tmp/capture.wav" ||
    die "real capture failed"
[[ "$(stat -c %s "$tmp/capture.wav")" -gt 44 ]] || die "capture is empty"
printf 'AUDIO_REAL_IO_OK playback=hw:%s capture=hw:%s bytes=%s\n' \
    "$play" "$capture" "$(stat -c %s "$tmp/capture.wav")"
