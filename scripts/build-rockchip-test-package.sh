#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
MODE=build

usage() { echo "usage: scripts/build-rockchip-test-package.sh [--check]"; }
die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

case "${1:-}" in
    "") ;;
    --check) MODE=check; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
esac
(( $# == 0 )) || { usage >&2; exit 2; }

declare -A CALLER_ENV=()
for env_name in BUILD_OUTPUT_DIR SDK_DIR ROCKCHIP_TEST_SOURCE_DIR \
        ROCKCHIP_TEST_PACKAGE_DIR ROCKCHIP_TEST_PACKAGE_CONFIG; do
    [[ -v "$env_name" ]] && CALLER_ENV["$env_name"]="${!env_name}"
done
if [[ -f "${PROJECT_DIR}/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "${PROJECT_DIR}/.env"
    set +a
fi
for env_name in "${!CALLER_ENV[@]}"; do
    printf -v "$env_name" '%s' "${CALLER_ENV[$env_name]}"
done

case "$(uname -m)" in
    aarch64|arm64) BUILD_OUTPUT_DIR="${BUILD_OUTPUT_DIR:-/var/lib/ubuntu-ci/build}" ;;
    x86_64|amd64) BUILD_OUTPUT_DIR="${BUILD_OUTPUT_DIR:-${PROJECT_DIR}/build}" ;;
    *) die "unsupported build host: $(uname -m)" ;;
esac
SDK_DIR="${SDK_DIR:-$(cd "${PROJECT_DIR}/.." && pwd)}"
ROCKCHIP_TEST_SOURCE_DIR="${ROCKCHIP_TEST_SOURCE_DIR:-${SDK_DIR}/external/rockchip-test}"
ROCKCHIP_TEST_PACKAGE_DIR="${ROCKCHIP_TEST_PACKAGE_DIR:-${BUILD_OUTPUT_DIR}/packages/rockchip-test}"
ROCKCHIP_TEST_PACKAGE_CONFIG="${ROCKCHIP_TEST_PACKAGE_CONFIG:-${PROJECT_DIR}/package/rockchip-test/package.conf}"

for path in "$BUILD_OUTPUT_DIR" "$ROCKCHIP_TEST_SOURCE_DIR" "$ROCKCHIP_TEST_PACKAGE_DIR"; do
    [[ "$path" == /* && "$path" != *[[:space:]]* ]] || die "invalid path: $path"
done
[[ -s "$ROCKCHIP_TEST_PACKAGE_CONFIG" ]] || die "missing package policy: $ROCKCHIP_TEST_PACKAGE_CONFIG"
# shellcheck disable=SC1090
source "$ROCKCHIP_TEST_PACKAGE_CONFIG"
[[ "$ROCKCHIP_TEST_PACKAGE" =~ ^[a-z0-9][a-z0-9+.-]*$ ]] || die "invalid package name"
[[ "$ROCKCHIP_TEST_VERSION" =~ ^[A-Za-z0-9.+:~_-]+$ ]] || die "invalid package version"
[[ "$ROCKCHIP_TEST_ARCHITECTURE" == all ]] || die "rockchip-test payload must be Architecture: all"
for tool in dpkg-deb find install sed sha256sum; do
    command -v "$tool" >/dev/null || die "missing package dependency: $tool"
done
for source_file in LICENSE rockchip_test.sh cpu/cpu_test.sh gpu/gpu_test.sh npu2/npu_test.sh; do
    [[ -s "${ROCKCHIP_TEST_SOURCE_DIR}/${source_file}" ]] || die "incomplete Rockchip test source: $source_file"
done
[[ -s "${ROCKCHIP_TEST_SOURCE_DIR}/npu2/model/RK356X/mobilenet_v1.rknn" ]] || die "missing Rockchip test model"

if [[ "$MODE" == check ]]; then
    info "Rockchip test package inputs are valid"
    echo "source=${ROCKCHIP_TEST_SOURCE_DIR}"
    echo "output=${ROCKCHIP_TEST_PACKAGE_DIR}"
    exit 0
fi

work_dir="${BUILD_OUTPUT_DIR}/work/rockchip-test"
package_root="${work_dir}/root"
[[ "$work_dir" == "${BUILD_OUTPUT_DIR%/}/work/rockchip-test" ]] || die "unsafe work directory"
rm -rf -- "$work_dir"
install -d -m 0755 "$package_root/DEBIAN" \
    "$package_root/usr/lib/rockchip-test" \
    "$package_root/usr/libexec" "$package_root/usr/bin" \
    "$package_root/usr/share/rockchip-test/profiles" \
    "$package_root/usr/share/doc/rockchip-test"
cp -a "${ROCKCHIP_TEST_SOURCE_DIR}/." "$package_root/usr/lib/rockchip-test/"
rm -rf -- "$package_root/usr/lib/rockchip-test/.git"

# Port persistent state and installed paths without modifying the SDK source.
while IFS= read -r -d '' script; do
    sed -i \
        -e 's#/data/rockchip-test#/var/lib/rockchip-test#g' \
        -e 's#/userdata/rockchip-test#/var/lib/rockchip-test#g' \
        -e 's#/userdata/rockchip/reboot_cnt#/var/lib/rockchip-test/reboot_cnt#g' \
        -e 's#/userdata/videos#/var/lib/rockchip-test/videos#g' \
        -e 's#/rockchip-test/#/usr/lib/rockchip-test/#g' "$script"
done < <(find "$package_root/usr/lib/rockchip-test" -type f -name '*.sh' -print0)

install -m 0755 "${PROJECT_DIR}/package/rockchip-test/src/rockchip-test" \
    "$package_root/usr/bin/rockchip-test"
install -m 0755 "${PROJECT_DIR}/package/rockchip-test/src/rockchip-test-qa" \
    "$package_root/usr/libexec/rockchip-test-qa"
install -m 0644 "${PROJECT_DIR}/package/rockchip-test/server.list" \
    "${PROJECT_DIR}/package/rockchip-test/desktop.list" \
    "$package_root/usr/share/rockchip-test/profiles/"
install -m 0644 "${ROCKCHIP_TEST_SOURCE_DIR}/LICENSE" \
    "$package_root/usr/share/doc/rockchip-test/copyright"
cat >"$package_root/DEBIAN/control" <<EOF
Package: ${ROCKCHIP_TEST_PACKAGE}
Version: ${ROCKCHIP_TEST_VERSION}
Architecture: ${ROCKCHIP_TEST_ARCHITECTURE}
Maintainer: Rockchip Ubuntu Image Team <builder@localhost>
Depends: bash, coreutils, iproute2, procps, systemd, util-linux
Suggests: alsa-utils, chromium, glmark2-es2, gstreamer1.0-tools, memtester, stress-ng, v4l-utils
Section: utils
Priority: optional
Description: Rockchip board validation tools
 Vendor test payload packaged with non-destructive Server and Desktop QA profiles.
EOF
find "$package_root" -type d -exec chmod 0755 {} + -exec chmod g-s {} +

install -d -m 2775 "$ROCKCHIP_TEST_PACKAGE_DIR"
package="${ROCKCHIP_TEST_PACKAGE_DIR}/${ROCKCHIP_TEST_PACKAGE}_${ROCKCHIP_TEST_VERSION}_${ROCKCHIP_TEST_ARCHITECTURE}.deb"
dpkg-deb --build --root-owner-group "$package_root" "$package" >/dev/null
[[ "$(dpkg-deb -f "$package" Package)" == "$ROCKCHIP_TEST_PACKAGE" ]] || die "package metadata mismatch"
package_contents="$(dpkg-deb --contents "$package")"
grep -Fq './usr/bin/rockchip-test' <<<"$package_contents" || die "package command is missing"
sha256sum "$package" >"${package}.sha256"
chmod 0644 "$package" "${package}.sha256"
info "Package: $package"
