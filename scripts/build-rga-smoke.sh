#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
asset_dir="${1:-}"
output="${2:-}"

die() { echo "ERROR: $*" >&2; exit 1; }

[[ "$asset_dir" == /* && -d "$asset_dir" && "$output" == /* ]] ||
    die "usage: $0 <absolute-platform-asset-directory> <absolute-output>"
for tool in dpkg-deb file install; do
    command -v "$tool" >/dev/null || die "missing RGA smoke build dependency: $tool"
done

runtime_deb="$("${SCRIPT_DIR}/find-local-deb.sh" "$asset_dir" rga-runtime)"
development_deb="$("${SCRIPT_DIR}/find-local-deb.sh" "$asset_dir" rga-development)"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
dpkg-deb -x "$runtime_deb" "$work/sysroot"
dpkg-deb -x "$development_deb" "$work/sysroot"

case "$(uname -m)" in
    aarch64|arm64) compiler="${CXX:-g++}" ;;
    x86_64|amd64) compiler="${CXX:-aarch64-linux-gnu-g++}" ;;
    *) die "unsupported RGA smoke build host: $(uname -m)" ;;
esac
command -v "$compiler" >/dev/null || die "missing ARM64 C++ compiler: $compiler"

install -d -m 0755 "$(dirname "$output")"
"$compiler" -std=c++17 -O2 -Wall -Wextra -Werror \
    -I"$work/sysroot/usr/include/rga" \
    "${PROJECT_DIR}/tests/target/assets/rga-smoke.cpp" \
    -L"$work/sysroot/usr/lib/aarch64-linux-gnu" \
    -Wl,-rpath-link,"$work/sysroot/usr/lib/aarch64-linux-gnu" \
    -Wl,--allow-shlib-undefined -lrga -ldl -pthread -o "$output"
file "$output" | grep -q 'ARM aarch64' || die "RGA smoke binary is not ARM64"
chmod 0755 "$output"
printf '%s\n' "$output"
