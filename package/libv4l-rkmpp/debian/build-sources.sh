#!/usr/bin/env bash
set -Eeuo pipefail

dest="${1:?usage: build-sources.sh <destdir>}"
SDK_DIR="${SDK_DIR:?SDK_DIR is required}"
SDK_OUTPUT_DIR="${SDK_OUTPUT_DIR:?SDK_OUTPUT_DIR is required}"
recipe="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
archive="${LIBV4L_RKMPP_SOURCE:-$SDK_DIR/buildroot/archives/libv4l-rkmpp-1.7.1-br1.tar.gz}"
[[ -s "$archive" ]] || { echo "ERROR: missing libv4l-rkmpp source: $archive" >&2; exit 1; }
tar -xzf "$archive" -C "$work"
src="$(find "$work" -mindepth 1 -maxdepth 1 -type d -print -quit)"

find_deb() {
    local pattern="$1"
    local -a matches=()
    mapfile -t matches < <(find "$SDK_OUTPUT_DIR/mpp" -maxdepth 1 -type f -name "$pattern" -print | sort)
    (( ${#matches[@]} == 1 )) || { echo "ERROR: $pattern resolved to ${#matches[@]} MPP packages" >&2; exit 1; }
    printf '%s\n' "${matches[0]}"
}
dpkg-deb -x "$(find_deb 'librockchip-mpp-dev_*_arm64.deb')" "$work/mpp-dev"
dpkg-deb -x "$(find_deb 'librockchip-mpp1_*_arm64.deb')" "$work/mpp-run"
cat >"$src/config.h" <<'EOF'
#define MAX_DEC_WIDTH 3840
#define MAX_DEC_HEIGHT 2160
#define MAX_ENC_WIDTH 1920
#define MAX_ENC_HEIGHT 1080
EOF
install -d -m 0755 "$dest/usr/lib/aarch64-linux-gnu/libv4l/plugins"
gcc -O2 -fPIC -shared \
    -o "$dest/usr/lib/aarch64-linux-gnu/libv4l/plugins/libv4l-rkmpp.so" \
    "$src"/src/*.c -I"$src" -I"$src/include" -I"$recipe/include" \
    -I"$work/mpp-dev/usr/include" -L"$work/mpp-run/usr/lib/aarch64-linux-gnu" \
    -Wl,-rpath-link,"$work/mpp-run/usr/lib/aarch64-linux-gnu" -lrockchip_mpp -lpthread
