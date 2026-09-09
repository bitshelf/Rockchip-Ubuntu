#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
rootfs="${1:-}"
asset_dir="${2:-}"
CONFIG="${LOCAL_DEB_INSTALL_CONFIG:-${PROJECT_DIR}/config/local-debs/install.conf}"

die() { echo "ERROR: $*" >&2; exit 1; }
[[ "$rootfs" == /* && -d "$rootfs" && "$rootfs" != / &&
   "$asset_dir" == /* && -s "$CONFIG" ]] ||
    die "usage: $0 <absolute-rootfs> <absolute-platform-asset-directory>"
# shellcheck disable=SC1090
source "$CONFIG"
declare -p LOCAL_DEB_INSTALL_PURPOSES LOCAL_DEB_HOLD_PURPOSES \
    LOCAL_DEB_FILE_ENTRIES LOCAL_DEB_ENABLE_SERVICES \
    LOCAL_DEB_DISABLE_SERVICES LOCAL_DEB_REQUIRED_ENTRIES >/dev/null 2>&1 ||
    die "incomplete local DEB install config"

declare -a temporary_debs=() packages=() hold_packages=()
cleanup() {
    local path
    for path in "${temporary_debs[@]}"; do rm -f -- "$rootfs$path"; done
}
trap cleanup EXIT

for purpose in "${LOCAL_DEB_INSTALL_PURPOSES[@]}"; do
    deb="$("$SCRIPT_DIR/find-local-deb.sh" "$asset_dir" "$purpose")"
    [[ "$(dpkg-deb -f "$deb" Architecture)" =~ ^(arm64|all)$ ]] ||
        die "unsupported package architecture: $deb"
    package="$(dpkg-deb -f "$deb" Package)"
    temporary="/tmp/$(basename "$deb")"
    install -D -m 0644 "$deb" "$rootfs$temporary"
    temporary_debs+=("$temporary")
    packages+=("$package")
done
chroot "$rootfs" dpkg -i "${temporary_debs[@]}"
cleanup
temporary_debs=()
chroot "$rootfs" ldconfig

for purpose in "${LOCAL_DEB_HOLD_PURPOSES[@]}"; do
    deb="$("$SCRIPT_DIR/find-local-deb.sh" "$asset_dir" "$purpose")"
    hold_packages+=("$(dpkg-deb -f "$deb" Package)")
done
(( ${#hold_packages[@]} == 0 )) || chroot "$rootfs" apt-mark hold "${hold_packages[@]}"

for entry in "${LOCAL_DEB_FILE_ENTRIES[@]}"; do
    IFS='|' read -r source target mode extra <<<"$entry"
    [[ -z "${extra:-}" && "$source" != /* && "$source" != *..* &&
       "$target" == /* && "$target" != *..* && "$mode" =~ ^0[0-7]{3}$ ]] ||
        die "invalid rootfs file entry: $entry"
    install -D -m "$mode" "$PROJECT_DIR/$source" "$rootfs$target"
done
for service in "${LOCAL_DEB_DISABLE_SERVICES[@]}"; do
    chroot "$rootfs" systemctl disable "$service" >/dev/null 2>&1 || true
    rm -f -- "$rootfs/etc/systemd/system"/*.wants/"$service"
done
for service in "${LOCAL_DEB_ENABLE_SERVICES[@]}"; do
    chroot "$rootfs" systemctl enable "$service" >/dev/null
done

shopt -s nullglob
for entry in "${LOCAL_DEB_REQUIRED_ENTRIES[@]}"; do
    IFS='|' read -r kind path extra <<<"$entry"
    [[ -z "${extra:-}" && "$path" == /* && "$path" != *..* ]] ||
        die "invalid required entry: $entry"
    case "$kind" in
        file) [[ -s "$rootfs$path" ]] || die "required installed file is missing: $path" ;;
        glob) matches=("$rootfs"$path); (( ${#matches[@]} > 0 )) || die "required installed glob is empty: $path" ;;
        *) die "unknown required entry type: $kind" ;;
    esac
done
shopt -u nullglob
printf 'local-debs.packages=%s\n' "${packages[*]}"
