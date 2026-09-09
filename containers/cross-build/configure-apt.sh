#!/usr/bin/env bash
set -Eeuo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }

TARGET_DEB_ARCH="${TARGET_DEB_ARCH:?TARGET_DEB_ARCH is required}"
NATIVE_APT_MIRROR="${NATIVE_APT_MIRROR:?NATIVE_APT_MIRROR is required}"
TARGET_APT_MIRROR="${TARGET_APT_MIRROR:?TARGET_APT_MIRROR is required}"
native_arch="$(dpkg --print-architecture)"

# shellcheck disable=SC1091
source /etc/os-release
[[ "${ID:-}" == ubuntu && -n "${VERSION_CODENAME:-}" ]] ||
    die "cross-build container must use an Ubuntu base image with VERSION_CODENAME"
[[ "$native_arch" == amd64 && "$TARGET_DEB_ARCH" == arm64 ]] ||
    die "unsupported build pair: ${native_arch} -> ${TARGET_DEB_ARCH}"
for mirror in "$NATIVE_APT_MIRROR" "$TARGET_APT_MIRROR"; do
    [[ "$mirror" =~ ^https?://[A-Za-z0-9./:_-]+$ ]] ||
        die "invalid APT mirror: $mirror"
done

rm -f /etc/apt/sources.list
find /etc/apt/sources.list.d -maxdepth 1 -type f -delete

cat >/etc/apt/sources.list.d/ubuntu.sources <<EOF
Types: deb deb-src
URIs: ${NATIVE_APT_MIRROR}
Suites: ${VERSION_CODENAME} ${VERSION_CODENAME}-updates ${VERSION_CODENAME}-backports ${VERSION_CODENAME}-security
Components: main universe restricted multiverse
Architectures: ${native_arch}
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF

dpkg --add-architecture "$TARGET_DEB_ARCH"
cat >>/etc/apt/sources.list.d/ubuntu.sources <<EOF

Types: deb
URIs: ${TARGET_APT_MIRROR}
Suites: ${VERSION_CODENAME} ${VERSION_CODENAME}-updates ${VERSION_CODENAME}-backports ${VERSION_CODENAME}-security
Components: main universe restricted multiverse
Architectures: ${TARGET_DEB_ARCH}
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF

cat >/etc/apt/apt.conf.d/80-cross-build <<'EOF'
Acquire::Retries "5";
Acquire::Languages "none";
EOF
