#!/usr/bin/env bash
set -Eeuo pipefail

fail() { echo "FAIL: $*" >&2; exit 1; }

alsa_card_count() {
    awk '/^[[:space:]]*[0-9]+[[:space:]]+\[/ { count++ } END { print count + 0 }' \
        /proc/asound/cards
}

alsa_pcm_count() {
    local direction="$1"
    awk -v direction="$direction" '
        $0 ~ direction { count++ }
        END { print count + 0 }
    ' /proc/asound/pcm
}

run_alsa_cli_qa() {
    local cards playback capture controls

    [[ "$(dpkg-query -W -f='${db:Status-Status}' alsa-utils 2>/dev/null)" == installed ]] ||
        fail "alsa-utils is not installed"
    for tool in alsactl aplay arecord amixer; do
        command -v "$tool" >/dev/null || fail "missing ALSA CLI: $tool"
        "$tool" --version >/dev/null 2>&1 || fail "$tool --version failed"
    done
    [[ -r /proc/asound/cards && -r /proc/asound/pcm ]] ||
        fail "ALSA procfs inventory is unavailable"

    cards="$(alsa_card_count)"
    playback="$(alsa_pcm_count playback)"
    capture="$(alsa_pcm_count capture)"
    (( cards > 0 )) || fail "no ALSA cards were enumerated"
    (( playback > 0 )) || fail "no ALSA playback PCM was enumerated"
    (( capture > 0 )) || fail "no ALSA capture PCM was enumerated"

    aplay -l >/dev/null || fail "aplay could not enumerate hardware"
    arecord -l >/dev/null || fail "arecord could not enumerate hardware"
    amixer -c 0 info >/dev/null || fail "amixer could not read card 0"
    controls="$(amixer -c 0 controls | awk '/^numid=/ { count++ } END { print count + 0 }')"
    (( controls > 0 )) || fail "card 0 exposes no mixer controls"

    printf 'ALSA_CLI_OK cards=%s playback=%s capture=%s controls=%s\n' \
        "$cards" "$playback" "$capture" "$controls"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    [[ $# -eq 0 ]] || fail "usage: $0"
    run_alsa_cli_qa
fi
