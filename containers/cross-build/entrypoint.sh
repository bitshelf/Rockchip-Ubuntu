#!/usr/bin/env bash
set -Eeuo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }

TARGET_DEB_ARCH="${TARGET_DEB_ARCH:-arm64}"
TARGET_GNU_TRIPLET="${TARGET_GNU_TRIPLET:-aarch64-linux-gnu}"
native_arch="${NATIVE_ARCH_OVERRIDE:-$(dpkg --print-architecture)}"

[[ "${native_arch}:${TARGET_DEB_ARCH}" == amd64:arm64 ]] ||
    die "unsupported build pair: ${native_arch} -> ${TARGET_DEB_ARCH}"
CC="${TARGET_GNU_TRIPLET}-gcc"
CXX="${TARGET_GNU_TRIPLET}-g++"
AR="${TARGET_GNU_TRIPLET}-ar"
STRIP="${TARGET_GNU_TRIPLET}-strip"
CROSS_COMPILE="${TARGET_GNU_TRIPLET}-"

export CC CXX AR STRIP CROSS_COMPILE
export PKG_CONFIG_LIBDIR="/usr/lib/${TARGET_GNU_TRIPLET}/pkgconfig:/usr/share/pkgconfig"

print_environment() {
    echo "host.arch=${native_arch}"
    echo "target.arch=${TARGET_DEB_ARCH}"
    echo "target.triplet=${TARGET_GNU_TRIPLET}"
    echo "compiler=${CC}"
    echo "cross_compile=${CROSS_COMPILE}"
    echo "pkg_config.libdir=${PKG_CONFIG_LIBDIR}"
}

check_environment() (
    local work machine
    for tool in "$CC" "$CXX" "$AR" "$STRIP" readelf; do
        command -v "$tool" >/dev/null || die "missing build tool: $tool"
    done
    [[ "$($CC -dumpmachine)" == "$TARGET_GNU_TRIPLET"* ]] ||
        die "compiler target does not match ${TARGET_GNU_TRIPLET}"
    work="$(mktemp -d)"
    trap 'rm -rf -- "$work"' EXIT
    cat >"$work/smoke.c" <<'EOF'
#include <stdio.h>
int main(void) { puts("cross-build-smoke"); return 0; }
EOF
    "$CC" -Wall -Wextra -Werror "$work/smoke.c" -o "$work/smoke"
    machine="$(readelf -h "$work/smoke" | sed -n 's/^[[:space:]]*Machine:[[:space:]]*//p')"
    [[ "$machine" == AArch64 ]] || die "unexpected output machine: $machine"
    print_environment
    echo "CROSS_BUILD_ENV_OK"
)

case "${1:---check}" in
    --check) check_environment ;;
    --print-env) print_environment ;;
    --shell) exec bash ;;
    --) shift; (( $# > 0 )) || die "missing command after --"; exec "$@" ;;
    *) exec "$@" ;;
esac
