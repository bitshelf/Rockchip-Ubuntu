#!/usr/bin/env bash
set -Eeuo pipefail
umask 0002

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG="${LOCAL_DEB_BUILD_CONFIG:-${PROJECT_DIR}/config/local-debs/build.conf}"
key="${1:-all}"

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

if [[ -f "$PROJECT_DIR/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "$PROJECT_DIR/.env"
    set +a
fi
case "$(uname -m)" in aarch64|arm64) ;; *) die "local runtime DEBs require a native ARM64 build host" ;; esac
SDK_DIR="${SDK_DIR:-$(cd "$PROJECT_DIR/.." && pwd)}"
SDK_OUTPUT_DIR="${SDK_OUTPUT_DIR:-$SDK_DIR/output}"
BUILD_OUTPUT_DIR="${BUILD_OUTPUT_DIR:-/var/lib/ubuntu-ci/build}"
work_root="${BUILD_OUTPUT_DIR}/work/local-debs"
[[ "$SDK_DIR" == /* && "$SDK_OUTPUT_DIR" == /* && "$BUILD_OUTPUT_DIR" == /* &&
   -s "$CONFIG" ]] || die "invalid SDK or build paths"
# shellcheck disable=SC1090
source "$CONFIG"
declare -p LOCAL_DEB_BUILD_ENTRIES >/dev/null 2>&1 ||
    die "LOCAL_DEB_BUILD_ENTRIES is missing"

run_root() {
    if (( EUID == 0 )); then "$@"; else sudo "$@"; fi
}

build_ubuntu_source() {
    local name="$1" source_package="$2" patch_dir="$3" output_dir="$4" patterns="$5"
    local work fetch source_dir patch patch_name
    work="$work_root/$name"
    fetch="$work/fetch"
    rm -rf -- "$work"
    mkdir -p "$fetch" "$SDK_OUTPUT_DIR/$output_dir"
    [[ -w "$SDK_OUTPUT_DIR/$output_dir" ]] ||
        die "local DEB output is not writable: $SDK_OUTPUT_DIR/$output_dir"
    (cd "$fetch" && apt-get source "$source_package")
    source_dir="$(find "$fetch" -mindepth 1 -maxdepth 1 -type d -print -quit)"
    [[ -n "$source_dir" && -f "$source_dir/debian/changelog" ]] ||
        die "cannot locate source tree for $source_package"
    install -d -m 0755 "$source_dir/debian/patches/rockchip"
    touch "$source_dir/debian/patches/series"
    while IFS= read -r -d '' patch; do
        patch_name="rockchip/$(basename "$patch")"
        install -m 0644 "$patch" "$source_dir/debian/patches/$patch_name"
        printf '%s\n' "$patch_name" >>"$source_dir/debian/patches/series"
    done < <(find "$PROJECT_DIR/$patch_dir" -maxdepth 1 -type f -name '*.patch' -print0 | sort -z)
    (
        cd "$source_dir"
        QUILT_PATCHES=debian/patches quilt push --fuzz=0 -a
        series="$(. /etc/os-release; printf '%s' "${VERSION_CODENAME:-unknown}")"
        DEBFULLNAME='Ubuntu image CI' DEBEMAIL='root@localhost' \
            dch --force-distribution --local "+rockchip.${series}." \
            --distribution "$series" 'Apply Rockchip V4L2 plugin support.'
        run_root env DEB_BUILD_OPTIONS=nocheck apt-get build-dep --yes ./
        DEB_BUILD_OPTIONS=nocheck dpkg-buildpackage --build=any --no-sign -j"${BUILD_JOBS:-$(nproc)}"
    )
    for pattern in $patterns; do
        # dpkg-buildpackage writes binary packages beside the unpacked source,
        # which is the apt source download directory rather than work itself.
        mapfile -t matches < <(find "$fetch" -maxdepth 1 -type f -name "$pattern" -print | sort)
        (( ${#matches[@]} == 1 )) || die "$name output $pattern resolved to ${#matches[@]} files"
        install -m 0644 "${matches[0]}" "$SDK_OUTPUT_DIR/$output_dir/"
    done
}

build_debian_recipe() {
    local name="$1" recipe="$2" output_dir="$3" patterns="$4"
    local work candidate
    work="$work_root/$name"
    rm -rf -- "$work"
    mkdir -p "$work/source" "$SDK_OUTPUT_DIR/$output_dir"
    [[ -w "$SDK_OUTPUT_DIR/$output_dir" ]] ||
        die "local DEB output is not writable: $SDK_OUTPUT_DIR/$output_dir"
    cp -a "$PROJECT_DIR/$recipe/." "$work/source/"
    (
        cd "$work/source"
        series="$(. /etc/os-release; printf '%s' "${VERSION_CODENAME:-unknown}")"
        sed "s/@SERIES@/$series/g" debian/changelog.in >debian/changelog
        run_root apt-get install --yes build-essential debhelper
        SDK_DIR="$SDK_DIR" SDK_OUTPUT_DIR="$SDK_OUTPUT_DIR" \
            dpkg-buildpackage --build=binary --no-sign -j"${BUILD_JOBS:-$(nproc)}"
    )
    for pattern in $patterns; do
        mapfile -t matches < <(find "$work" -maxdepth 1 -type f -name "$pattern" -print | sort)
        (( ${#matches[@]} == 1 )) || die "$name output $pattern resolved to ${#matches[@]} files"
        install -m 0644 "${matches[0]}" "$SDK_OUTPUT_DIR/$output_dir/"
    done
}

selected=0
for entry in "${LOCAL_DEB_BUILD_ENTRIES[@]}"; do
    IFS='|' read -r name builder source patch_dir output_dir patterns prepared_packages extra <<<"$entry"
    [[ -z "${extra:-}" && -n "$name" && -n "$patterns" ]] || die "invalid build entry: $entry"
    [[ "$key" == all || "$key" == "$name" ]] || continue
    selected=1
    info "Build local DEBs: $name"
    for prepared_package in $prepared_packages; do
        "$SCRIPT_DIR/prepare-local-debs.sh" "$prepared_package"
    done
    case "$builder" in
        ubuntu-source) build_ubuntu_source "$name" "$source" "$patch_dir" "$output_dir" "$patterns" ;;
        debian-recipe) build_debian_recipe "$name" "$source" "$output_dir" "$patterns" ;;
        *) die "unknown local DEB builder: $builder" ;;
    esac
done
(( selected == 1 )) || die "unknown package key: $key"
