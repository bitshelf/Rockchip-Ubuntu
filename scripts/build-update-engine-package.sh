#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_ARCHIVE="${1:-}"
SOURCE_INFO="${2:-}"
OUTPUT_DIR="${3:-}"
PACKAGE_CONFIG="${PROJECT_DIR}/package/update-engine/package.conf"
PACKAGE_FILES="${PROJECT_DIR}/package/update-engine"
PATCH_DIR="${PACKAGE_FILES}/patches"

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

[[ -s "$SOURCE_ARCHIVE" && ! -L "$SOURCE_ARCHIVE" &&
   -s "$SOURCE_INFO" && ! -L "$SOURCE_INFO" &&
   "$OUTPUT_DIR" == /* && "$OUTPUT_DIR" != *[[:space:]]* ]] ||
    die "usage: $0 <source.tar> <source-info> <absolute-output-directory>"
[[ -s "$PACKAGE_CONFIG" ]] || die "missing package configuration: $PACKAGE_CONFIG"
# shellcheck disable=SC1090
source "$PACKAGE_CONFIG"
for variable in UPDATE_ENGINE_PACKAGE_NAME UPDATE_ENGINE_UPSTREAM_VERSION \
        UPDATE_ENGINE_DEBIAN_REVISION UPDATE_ENGINE_MAINTAINER \
        UPDATE_ENGINE_DESCRIPTION; do
    [[ -n "${!variable:-}" && "${!variable}" != *$'\n'* ]] ||
        die "invalid package configuration: $variable"
done
for tool in dpkg-deb file find gzip install md5sum patch readelf sha256sum tar xargs; do
    command -v "$tool" >/dev/null || die "missing package build tool: $tool"
done

grep -Fxq 'schema=ubuntu-update-engine-source-v1' "$SOURCE_INFO" ||
    die "unsupported source metadata"
source_commit="$(awk -F= '$1 == "source.commit" {print $2}' "$SOURCE_INFO")"
source_short="$(awk -F= '$1 == "source.commit.short" {print $2}' "$SOURCE_INFO")"
source_date="$(awk -F= '$1 == "source.date" {print $2}' "$SOURCE_INFO")"
archive_sha="$(awk -F= '$1 == "archive.sha256" {print $2}' "$SOURCE_INFO")"
[[ "$source_commit" =~ ^[0-9a-f]{40}$ && "$source_short" =~ ^[0-9a-f]{7,12}$ &&
   "$source_date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ &&
   "$archive_sha" =~ ^[0-9a-f]{64}$ ]] || die "invalid source metadata"
[[ "$(sha256sum "$SOURCE_ARCHIVE" | awk '{print $1}')" == "$archive_sha" ]] ||
    die "source archive checksum mismatch"
tar -tf "$SOURCE_ARCHIVE" | awk '
    /^\// || /(^|\/)\.\.($|\/)/ {bad=1}
    END {exit (NR == 0 || bad)}
' || die "source archive contains an unsafe path"

work="$(mktemp -d)"
cleanup() { rm -rf -- "$work"; }
trap cleanup EXIT
source_root="$work/source"
objects_root="$work/objects"
package_root="$work/package"
install -d "$source_root" "$objects_root" "$package_root"
tar -xf "$SOURCE_ARCHIVE" -C "$source_root"
[[ -s "$source_root/update_engine/main.c" ]] || die "source archive is incomplete"
while IFS= read -r patch_file; do
    info "Apply $(basename "$patch_file")"
    patch --batch --forward -d "$source_root" -p1 <"$patch_file"
done < <(find "$PATCH_DIR" -maxdepth 1 -type f -name '*.patch' -print | sort)

cat >"$source_root/recovery_autogenerate.h" <<EOF
#define GIT_COMMIT_INFO -g${source_short}-${source_date//-/}
EOF
compiler="${CC:-}"
strip_tool="${STRIP:-}"
if [[ -z "$compiler" ]]; then
    case "$(uname -m)" in
        aarch64|arm64) compiler=gcc; strip_tool="${strip_tool:-strip}" ;;
        x86_64|amd64) compiler=aarch64-linux-gnu-gcc; strip_tool="${strip_tool:-aarch64-linux-gnu-strip}" ;;
        *) die "unsupported package build host: $(uname -m)" ;;
    esac
fi
[[ -n "$strip_tool" ]] || strip_tool="${compiler%gcc}strip"
for tool in "$compiler" "$strip_tool"; do
    command -v "$tool" >/dev/null || die "missing ARM64 build tool: $tool"
done

sources=(
    mtdutils/mounts.c mtdutils/mtdutils.c mtdutils/rk29.c
    update_engine/rkbootloader.c update_engine/download.c
    update_engine/flash_image.c update_engine/log.c update_engine/main.c
    update_engine/md5.c update_engine/md5sum.c update_engine/rkimage.c
    update_engine/rktools.c update_engine/rkboot.c update_engine/crc.c
    update_engine/update.c update_engine/do_patch.c
)
flags=(-O2 -g -fstack-protector-strong -fPIE -D_FORTIFY_SOURCE=3
    -D_GNU_SOURCE -Wall -Wextra -Wformat -Werror=format-security
    "-I${source_root}")
objects=()
for source_file in "${sources[@]}"; do
    object="$objects_root/${source_file//\//_}.o"
    "$compiler" "${flags[@]}" -c "$source_root/$source_file" -o "$object"
    objects+=("$object")
done
binary="$work/updateEngine"
"$compiler" -pie -Wl,-z,relro -Wl,-z,now -Wl,--as-needed \
    -o "$binary" "${objects[@]}" -pthread -lcurl -lbz2
"$strip_tool" --strip-unneeded "$binary"
readelf -h "$binary" | grep -Eq 'Machine:[[:space:]]+AArch64' ||
    die "updateEngine output is not AArch64"
readelf -d "$binary" | grep -q 'Shared library: \[libcurl.so' ||
    die "updateEngine is not dynamically linked with libcurl"

source_date_compact="${source_date//-/}"
package_version="${UPDATE_ENGINE_UPSTREAM_VERSION}+git${source_date_compact}.${source_short}-${UPDATE_ENGINE_DEBIAN_REVISION}"
install -d -m 0755 "$package_root/DEBIAN" "$package_root/usr/bin" \
    "$package_root/usr/lib/udev/rules.d" \
    "$package_root/usr/share/doc/$UPDATE_ENGINE_PACKAGE_NAME"
install -m 0755 "$binary" "$package_root/usr/bin/updateEngine"
install -m 0644 "$PACKAGE_FILES/99-rockchip-block-by-name.rules" \
    "$package_root/usr/lib/udev/rules.d/"
install -m 0644 "$PACKAGE_FILES/copyright" \
    "$package_root/usr/share/doc/$UPDATE_ENGINE_PACKAGE_NAME/copyright"
cat >"$package_root/usr/share/doc/$UPDATE_ENGINE_PACKAGE_NAME/changelog.Debian" <<EOF
${UPDATE_ENGINE_PACKAGE_NAME} (${package_version}) unstable; urgency=medium

  * Build Rockchip updateEngine from SDK commit ${source_commit}.
  * Install Ubuntu-compatible /dev/block/by-name links.

 -- ${UPDATE_ENGINE_MAINTAINER}  $(date -R -d "${source_date} 00:00:00 UTC")
EOF
gzip -n -9 "$package_root/usr/share/doc/$UPDATE_ENGINE_PACKAGE_NAME/changelog.Debian"
cat >"$package_root/DEBIAN/control" <<EOF
Package: ${UPDATE_ENGINE_PACKAGE_NAME}
Version: ${package_version}
Architecture: arm64
Section: admin
Priority: optional
Maintainer: ${UPDATE_ENGINE_MAINTAINER}
Depends: libc6, libbz2-1.0, libcurl4t64 | libcurl4, coreutils, util-linux, udev
Description: ${UPDATE_ENGINE_DESCRIPTION}
 Built from the staged Rockchip SDK recovery source. Installs updateEngine and
 Ubuntu-compatible /dev/block/by-name partition links.
EOF
cat >"$package_root/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
if command -v udevadm >/dev/null 2>&1; then
    udevadm control --reload-rules || true
    udevadm trigger --subsystem-match=block --action=change || true
    udevadm settle || true
fi
exit 0
EOF
chmod 0755 "$package_root/DEBIAN/postinst"
(
    cd "$package_root"
    find usr -type f -print0 | sort -z | xargs -0 md5sum
) >"$package_root/DEBIAN/md5sums"

install -d -m 2775 "$OUTPUT_DIR"
output="$OUTPUT_DIR/${UPDATE_ENGINE_PACKAGE_NAME}_${package_version}_arm64.deb"
rm -f -- "$OUTPUT_DIR/${UPDATE_ENGINE_PACKAGE_NAME}_"*_arm64.deb
dpkg-deb --root-owner-group --build "$package_root" "$output" >/dev/null
[[ "$(dpkg-deb -f "$output" Package)" == "$UPDATE_ENGINE_PACKAGE_NAME" &&
   "$(dpkg-deb -f "$output" Architecture)" == arm64 ]] ||
    die "invalid updateEngine Debian package"
(cd "$OUTPUT_DIR" && sha256sum "$(basename "$output")" >"$(basename "$output").sha256")
cat >"${output}.build-info" <<EOF
schema=ubuntu-update-engine-package-v1
package=${UPDATE_ENGINE_PACKAGE_NAME}
version=${package_version}
architecture=arm64
source.commit=${source_commit}
source.archive.sha256=${archive_sha}
binary.sha256=$(sha256sum "$binary" | awk '{print $1}')
EOF
chmod 0644 "$output" "${output}.sha256" "${output}.build-info"
info "Package built: $output"
