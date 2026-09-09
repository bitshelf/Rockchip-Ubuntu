#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

grep -Eq '^[[:space:]]+\*[[:space:]]+alsa-utils$' \
    "$PROJECT_DIR/config/ubuntu-image/seeds/rockchip-server" ||
    fail "alsa-utils is missing from the Server seed"
grep -Fq 'tests/target/test-alsa-utils.sh|/usr/libexec/ubuntu-alsa-cli-qa|0755' \
    "$PROJECT_DIR/config/local-debs/install.conf" ||
    fail "ALSA target QA is not installed into the image"
for contract in 'alsactl aplay arecord amixer' 'aplay -l' 'arecord -l' \
        'amixer -c 0 info' 'ALSA_CLI_OK'; do
    grep -Fq "$contract" "$PROJECT_DIR/tests/target/test-alsa-utils.sh" ||
        fail "missing ALSA CLI contract: $contract"
done
! grep -Eq '^[[:space:]]*(speaker-test|aplay[[:space:]]+[^-]|arecord[[:space:]]+[^-])' \
    "$PROJECT_DIR/tests/target/test-alsa-utils.sh" ||
    fail "basic ALSA CLI QA must not play or record audio"

echo "alsa-utils CLI contracts passed"
