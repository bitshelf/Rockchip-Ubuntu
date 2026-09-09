#!/usr/bin/env bash
set -Eeuo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

EXAMPLE_NAME="${EXAMPLE_NAME:?EXAMPLE_NAME is required}"
SOURCE_PACKAGE="${SOURCE_PACKAGE:?SOURCE_PACKAGE is required}"
BUILD_JOBS="${BUILD_JOBS:-$(nproc)}"
WORKSPACE_ROOT="${WORKSPACE_ROOT:-/workspace}"

[[ "$EXAMPLE_NAME" =~ ^[a-z0-9][a-z0-9+.-]*$ ]] ||
    die "invalid example name: $EXAMPLE_NAME"
[[ "$SOURCE_PACKAGE" =~ ^[a-z0-9][a-z0-9+.-]*$ ]] ||
    die "invalid source package: $SOURCE_PACKAGE"
[[ "$BUILD_JOBS" =~ ^[1-9][0-9]*$ ]] ||
    die "BUILD_JOBS must be a positive integer"
[[ "$(dpkg --print-architecture)" == amd64 ]] ||
    die "Debian package example requires an amd64 container"
[[ "$WORKSPACE_ROOT" == /* && -d "$WORKSPACE_ROOT" ]] ||
    die "WORKSPACE_ROOT must be an absolute repository mount"

work="/out/work/${EXAMPLE_NAME}"
fetch="${work}/source"
publish="/out/packages/${EXAMPLE_NAME}"
rm -rf -- "$work" "$publish"
mkdir -p "$fetch" "$publish"

info "Fetch Ubuntu source package: ${SOURCE_PACKAGE}"
(
    cd "$fetch"
    apt-get source "$SOURCE_PACKAGE"
)
source_dir="$(find "$fetch" -mindepth 1 -maxdepth 1 -type d -print -quit)"
[[ -n "$source_dir" && -f "${source_dir}/debian/changelog" ]] ||
    die "cannot locate extracted source for ${SOURCE_PACKAGE}"
source_version="$(dpkg-parsechangelog -l"${source_dir}/debian/changelog" -SVersion)"
package_version="$source_version"
patch_count=0
patch_names=none
patch_config="${WORKSPACE_ROOT}/package/${EXAMPLE_NAME}"
series="${patch_config}/series"
if [[ -f "$series" ]]; then
    [[ -d "${patch_config}/patches" && -s "${patch_config}/version-suffix" ]] ||
        die "incomplete patch configuration for ${EXAMPLE_NAME}"
    version_suffix="$(<"${patch_config}/version-suffix")"
    [[ "$version_suffix" =~ ^\+[a-z0-9][a-z0-9.+~]*$ ]] ||
        die "invalid Debian version suffix: $version_suffix"
    applied=()
    while IFS= read -r patch_name || [[ -n "$patch_name" ]]; do
        [[ -n "$patch_name" && "$patch_name" != \#* ]] || continue
        [[ "$patch_name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*\.patch$ ]] ||
            die "invalid patch name in ${series}: $patch_name"
        patch_file="${patch_config}/patches/${patch_name}"
        [[ -f "$patch_file" && ! -L "$patch_file" ]] ||
            die "missing regular patch file: $patch_file"
        info "Apply ${EXAMPLE_NAME} patch: ${patch_name}"
        patch --batch --forward -d "$source_dir" -p1 <"$patch_file"
        applied+=("$patch_name")
        (( patch_count += 1 ))
    done <"$series"
    (( patch_count > 0 )) || die "empty patch series: $series"
    package_version="${source_version}${version_suffix}"
    target_distribution="$(sed -n 's/^VERSION_CODENAME=//p' /etc/os-release)"
    [[ "$target_distribution" =~ ^[a-z][a-z0-9-]*$ ]] ||
        die "target image has no valid VERSION_CODENAME"
    DEBFULLNAME='Rockchip Ubuntu Builder' \
        DEBEMAIL='builder@localhost.localdomain' \
        dch --changelog "${source_dir}/debian/changelog" \
            --newversion "$package_version" --distribution "$target_distribution" \
            "Apply the repository ${EXAMPLE_NAME} patch series."
    patch_names="$(IFS=,; echo "${applied[*]}")"
fi

info "Cross-build ${SOURCE_PACKAGE} ${package_version} for ARM64"
(
    cd "$source_dir"
    DEB_BUILD_OPTIONS=nocheck \
    DEB_BUILD_PROFILES='cross nodoc nocheck' \
        dpkg-buildpackage --host-arch arm64 --build=any,all \
            --no-sign -j"$BUILD_JOBS"
)

shopt -s nullglob
packages=("$fetch"/*.deb)
(( ${#packages[@]} > 0 )) || die "dpkg-buildpackage produced no packages"
published=0
for package in "${packages[@]}"; do
    package_arch="$(dpkg-deb -f "$package" Architecture)"
    [[ "$package_arch" == arm64 || "$package_arch" == all ]] || continue
    install -m 0644 "$package" "$publish/"
    (( published += 1 ))
done
(( published > 0 )) || die "no ARM64/all packages were produced"

qa_root="${work}/qa-root"
mkdir -p "$qa_root"
for package in "$publish"/*.deb; do
    [[ "$(dpkg-deb -f "$package" Architecture)" == arm64 ]] || continue
    package_root="${qa_root}/$(basename "$package" .deb)"
    dpkg-deb --extract "$package" "$package_root"
    while IFS= read -r elf; do
        machine="$(readelf -h "$elf" | sed -n 's/^[[:space:]]*Machine:[[:space:]]*//p')"
        [[ "$machine" == AArch64 ]] || die "non-AArch64 ELF in $(basename "$package"): $elf"
    done < <(find "$package_root" -type f -exec sh -c \
        'file -b "$1" | grep -q "^ELF" && printf "%s\n" "$1"' _ {} \;)
done

{
    printf 'source.package=%s\n' "$SOURCE_PACKAGE"
    printf 'source.version=%s\n' "$source_version"
    printf 'package.version=%s\n' "$package_version"
    printf 'patch.count=%s\n' "$patch_count"
    printf 'patch.series=%s\n' "$patch_names"
    printf 'build.arch=amd64\n'
    printf 'host.arch=arm64\n'
    printf 'package.count=%s\n' "$published"
} >"${publish}/build-info"
(
    cd "$publish"
    sha256sum -- *.deb >SHA256SUMS
)
rm -rf -- "$work"
info "Published ARM64 Debian packages: ${publish}"
echo "CROSS_DEB_EXAMPLE_OK=${EXAMPLE_NAME}"
