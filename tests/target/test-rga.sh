#!/usr/bin/env bash
set -Eeuo pipefail

fail() { echo "FAIL: $*" >&2; exit 1; }

[[ "$(uname -m)" == aarch64 ]] || fail "target is not ARM64"
[[ -c /dev/rga ]] || fail "/dev/rga is missing"
[[ -x /usr/libexec/ubuntu-rga-smoke ]] || fail "RGA smoke binary is missing"
[[ "$(dpkg-query -W -f='${db:Status-Status}' librga2 2>/dev/null)" == installed ]] ||
    fail "librga2 is not installed"
apt-mark showhold | grep -Fxq librga2 || fail "librga2 is not held"
# Consume the entire cache: grep -q can close the pipe early and make
# ldconfig fail with SIGPIPE under pipefail on a large image.
ldconfig -p | grep -E 'librga\.so\.2 .* /usr/lib/aarch64-linux-gnu/' >/dev/null ||
    fail "librga.so.2 is not in the dynamic linker cache"

output="$(timeout 60 /usr/libexec/ubuntu-rga-smoke 2>&1)" || {
    printf '%s\n' "$output" >&2
    fail "RGA dma-buf fill failed"
}
printf '%s\n' "$output"
grep -Fxq RGA_SMOKE_OK <<<"$output" || fail "RGA_SMOKE_OK is missing"
