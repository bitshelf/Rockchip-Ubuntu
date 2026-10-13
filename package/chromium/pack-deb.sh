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
[[ -f "$stage/usr/lib/chromium-browser/chrome_sandbox" ]] || die "missing sandbox helper"
mv "$stage/usr/lib/chromium-browser/chrome_sandbox" "$stage/usr/lib/chromium-browser/chrome-sandbox"
chmod 4755 "$stage/usr/lib/chromium-browser/chrome-sandbox"
cat >"$stage/usr/bin/chromium" <<'EOF'
#!/bin/sh
# The image chooses its GPU policy; explicit caller adapter selection wins.
rockchip_adapter_explicit=0
for rockchip_arg do
    case "$rockchip_arg" in --use-webgpu-adapter=*) rockchip_adapter_explicit=1 ;; esac
done
rockchip_backend=
if [ -r /etc/chromium/rockchip-webgpu-backend ]; then
    IFS= read -r rockchip_backend </etc/chromium/rockchip-webgpu-backend || :
fi
if [ "$rockchip_adapter_explicit" = 0 ] && [ "$rockchip_backend" = gles-compat ]; then
    set -- --use-angle=gl --use-webgpu-adapter=opengles --force-webgpu-compat --disable-features=Vulkan "$@"
fi
exec /usr/lib/chromium-browser/chrome --gpu-sandbox-start-early --enable-features=AcceleratedVideoDecoder,PreferV4L2VideoAcceleration "$@"
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
Version: ${version}-rockchip1
Section: web
Priority: optional
Architecture: arm64
Maintainer: Ubuntu Builder <builder@localhost>
Depends: libv4l-0t64, libv4l-rkmpp1, ca-certificates, libc6, libdrm2, libgbm1, libnss3, libnspr4, libasound2t64, libatk1.0-0t64, libatk-bridge2.0-0t64, libcups2t64, libdbus-1-3, libfontconfig1, libgtk-3-0t64, libx11-6, libxcb1, libxcomposite1, libxdamage1, libxext6, libxfixes3, libxkbcommon0, libxrandr2
Description: Chromium browser with MPP and hardware GPU integration
 Cross-built ARM64 Chromium with Wayland/V4L2 integration.
EOF
dpkg-deb --build --root-owner-group "$stage" "$publish/chromium_${version}_arm64.deb" >/dev/null
(cd "$publish" && sha256sum *.deb >SHA256SUMS)
printf 'source.version=%s\nformat=deb\narchitecture=arm64\n' "$version" >"$publish/build-info"
[[ ! -f "$output_root/chromium/build-info" ]] || cat "$output_root/chromium/build-info" >> "$publish/build-info"
echo "CHROMIUM_ARM64_DEB_OK"
