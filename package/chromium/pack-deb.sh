#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C
die() { echo "ERROR: $*" >&2; exit 1; }
version="${CHROMIUM_VERSION:?CHROMIUM_VERSION is required}"
output_root="${CROSS_OUTPUT_DIR:?CROSS_OUTPUT_DIR is required}"
[[ "$output_root" == /* && "$output_root" != / ]] || die "CROSS_OUTPUT_DIR must be an absolute non-root path"
payload="${output_root}/chromium/payload"
publish="${output_root}/packages/chromium"
stage="${output_root}/work/chromium-deb"
[[ -x "${payload}/usr/lib/chromium-browser/chrome" ]] || die "missing Chromium payload"
[[ "$version" =~ ^[0-9][A-Za-z0-9.+~-]*$ ]] || die "invalid Chromium version"
command -v dpkg-deb >/dev/null || die "dpkg-deb is required"
command -v readelf >/dev/null || die "readelf is required"
[[ -f "$payload/usr/lib/chromium-browser/chrome" ]] || die "missing browser ELF"
readelf -h "$payload/usr/lib/chromium-browser/chrome" | grep -Eq 'Machine:[[:space:]]+AArch64$' || die "browser is not AArch64"
while IFS= read -r -d '' candidate; do
    if [[ "$(head -c 4 "$candidate" | od -An -tx1 | tr -d ' \n')" == 7f454c46 ]]; then
        readelf -h "$candidate" | grep -Eq 'Machine:[[:space:]]+AArch64$' || die "non-AArch64 payload ELF: $candidate"
    fi
done < <(find "$payload" -type f -print0)
rm -rf -- "$stage" "$publish"
install -d "$stage/DEBIAN" "$stage/usr/bin" "$stage/usr/share/applications" "$publish"
cp -a "$payload/usr" "$stage/"
cat >"$stage/usr/bin/chromium" <<'EOF'
#!/bin/sh
exec /usr/lib/chromium-browser/chrome "$@"
EOF
chmod 0755 "$stage/usr/bin/chromium"
cat >"$stage/usr/share/applications/chromium.desktop" <<'EOF'
[Desktop Entry]
Name=Chromium
Exec=chromium %U
Type=Application
Categories=Network;WebBrowser;
EOF
cat >"$stage/DEBIAN/control" <<EOF
Package: chromium
Version: ${version}-rk3576
Section: web
Priority: optional
Architecture: arm64
Maintainer: RK3576 Ubuntu Builder <builder@localhost>
Depends: ca-certificates, libc6, libdrm2, libgbm1, libnss3, libx11-6, libxcb1, libxcomposite1, libxdamage1, libxext6, libxfixes3, libxkbcommon0, libxrandr2
Description: Chromium browser for RK3576 (patched ARM64 build)
 Cross-built Chromium with RK3576 Wayland/V4L2 patches.
EOF
dpkg-deb --build --root-owner-group "$stage" "$publish/chromium_${version}_arm64.deb" >/dev/null
(cd "$publish" && sha256sum *.deb >SHA256SUMS)
printf 'source.version=%s\nformat=deb\narchitecture=arm64\n' "$version" >"$publish/build-info"
echo "CHROMIUM_ARM64_DEB_OK"
