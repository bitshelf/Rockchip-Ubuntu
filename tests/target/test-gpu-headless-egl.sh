#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[[ "$(id -u)" -eq 0 ]] || { echo "FAIL: run as root" >&2; exit 1; }
mapfile -t packages < <(
    dpkg-query -W -f='${binary:Package}\t${db:Status-Status}\n' 'libmali-*' \
        2>/dev/null | awk '$2 == "installed" { print $1 }'
)
(( ${#packages[@]} == 1 )) || {
    echo "FAIL: expected one installed libmali package, found ${#packages[@]}" >&2
    exit 1
}
package="${packages[0]}"
apt-mark showhold | grep -Fxq "$package" || {
    echo "FAIL: libmali package is not held" >&2
    exit 1
}
[[ -c /dev/mali0 ]] || { echo "FAIL: /dev/mali0 is unavailable" >&2; exit 1; }
egl_path="$(ldconfig -p | awk '$1 == "libEGL.so.1" { print $NF; exit }')"
[[ "$egl_path" == /usr/lib/aarch64-linux-gnu/mali/* ]] || {
    echo "FAIL: libEGL.so.1 resolves to ${egl_path:-missing}" >&2
    exit 1
}

LIBMALI_PACKAGE="$package" exec python3 "${SCRIPT_DIR}/headless-egl.py"
