#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
MODE=build
VARIANT=server

usage() {
    cat <<'EOF'
usage: scripts/build-server.sh [--variant server|desktop] [--check]

Build an Ubuntu 26 Server ARM64 rootfs with ubuntu-image. The build supports
native ARM64 and x86_64 hosts with qemu-aarch64 binfmt registration.
EOF
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

info() {
    echo "==> $*"
}

find_single_artifact() {
    local directory="$1" pattern="$2" description="$3"
    local -a matches=()

    mapfile -d '' -t matches < <(
        find "$directory" -maxdepth 1 -type f -name "$pattern" \
            -print0 | sort -z
    )
    (( ${#matches[@]} == 1 )) ||
        die "expected one ${description} in ${directory}, found ${#matches[@]}"
    printf '%s\n' "${matches[0]}"
}

host_arch() {
    case "$(uname -m)" in
        aarch64|arm64) echo arm64 ;;
        x86_64|amd64) echo amd64 ;;
        *) die "unsupported build-host architecture: $(uname -m)" ;;
    esac
}

BUILD_ARGS=("$@")
while (( $# > 0 )); do
    case "$1" in
        --variant) VARIANT="${2:-}"; (( $# >= 2 )) || { usage >&2; exit 2; }; shift 2 ;;
        --check) MODE=check; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done
[[ "$VARIANT" == server || "$VARIANT" == desktop ]] || die "unsupported variant: $VARIANT"

declare -A CALLER_ENV=()
for env_name in BUILD_OUTPUT_DIR UBUNTU_PORTS_MIRROR UBUNTU_IMAGE APT_PROXY \
    HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy; do
    if [[ -v "$env_name" ]]; then
        CALLER_ENV["$env_name"]="${!env_name}"
    fi
done
if [[ -f "${PROJECT_DIR}/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "${PROJECT_DIR}/.env"
    set +a
fi
for env_name in "${!CALLER_ENV[@]}"; do
    printf -v "$env_name" '%s' "${CALLER_ENV[$env_name]}"
    export "$env_name"
done

UBUNTU_SERIES=resolute
UBUNTU_VERSION=26.04
ARCHITECTURE=arm64
HOST_ARCH="$(host_arch)"
if [[ "$HOST_ARCH" == arm64 ]]; then
    BUILD_OUTPUT_DIR="${BUILD_OUTPUT_DIR:-/var/lib/ubuntu-ci/build}"
else
    BUILD_OUTPUT_DIR="${BUILD_OUTPUT_DIR:-${PROJECT_DIR}/build}"
fi
UBUNTU_PORTS_MIRROR="${UBUNTU_PORTS_MIRROR:-https://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports/}"
UBUNTU_IMAGE="${UBUNTU_IMAGE:-$(command -v ubuntu-image || true)}"
UBUNTU_IMAGE="${UBUNTU_IMAGE:-/snap/bin/ubuntu-image}"
IMAGE_BASENAME="ubuntu-${UBUNTU_VERSION}-${VARIANT}-${ARCHITECTURE}"
IMAGES_DIR="${BUILD_OUTPUT_DIR}/images"
LOGS_DIR="${BUILD_OUTPUT_DIR}/logs"
WORK_DIR="${BUILD_OUTPUT_DIR}/work/${UBUNTU_SERIES}-${VARIANT}"
UI_OUTPUT="${WORK_DIR}/output"
UI_WORK="${WORK_DIR}/ubuntu-image"
SEED_CACHE_ROOT="${BUILD_OUTPUT_DIR}/cache/ubuntu-image-seeds/${UBUNTU_SERIES}"
DEFINITION_TEMPLATE="${PROJECT_DIR}/config/ubuntu-image/${UBUNTU_SERIES}-server-${ARCHITECTURE}.yaml.in"
DEFINITION="${WORK_DIR}/${UBUNTU_SERIES}-${VARIANT}-${ARCHITECTURE}.yaml"
APT_POLICY="${PROJECT_DIR}/config/ubuntu-image/apt.conf"

[[ "$BUILD_OUTPUT_DIR" == /* ]] ||
    die "BUILD_OUTPUT_DIR must be an absolute path: $BUILD_OUTPUT_DIR"
[[ "$BUILD_OUTPUT_DIR" != *[[:space:]]* ]] ||
    die "BUILD_OUTPUT_DIR must not contain whitespace"
[[ "$UBUNTU_PORTS_MIRROR" =~ ^https?://[A-Za-z0-9./:_-]+$ ]] ||
    die "invalid UBUNTU_PORTS_MIRROR: $UBUNTU_PORTS_MIRROR"
[[ -f "$DEFINITION_TEMPLATE" ]] ||
    die "missing ubuntu-image definition: $DEFINITION_TEMPLATE"
[[ -f "$APT_POLICY" ]] ||
    die "missing rootfs APT policy: $APT_POLICY"

if [[ "$VARIANT" == desktop ]]; then
    [[ -s "${PROJECT_DIR}/config/ubuntu-image/desktop.packages" ]] || die "missing GNOME package list"
fi

for tool in awk findmnt git install jq sed sha256sum tar umount wget; do
    command -v "$tool" >/dev/null || die "missing build dependency: $tool"
done
[[ -x "$UBUNTU_IMAGE" ]] ||
    die "ubuntu-image is unavailable; run scripts/setup-build-host.sh"
if [[ "$HOST_ARCH" == amd64 ]]; then
    [[ -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]] ||
        die "qemu-aarch64 binfmt is not registered; run scripts/setup-build-host.sh"
fi

if [[ "$MODE" == check ]]; then
    info "${VARIANT} build configuration is valid"
    echo "host.arch=${HOST_ARCH}"
    echo "image=${UBUNTU_SERIES}/${UBUNTU_VERSION}/${VARIANT}/${ARCHITECTURE}"
    echo "output=${BUILD_OUTPUT_DIR}"
    echo "mirror=${UBUNTU_PORTS_MIRROR}"
    exit 0
fi

if [[ "$EUID" -ne 0 ]]; then
    exec sudo --preserve-env=BUILD_OUTPUT_DIR,UBUNTU_PORTS_MIRROR,UBUNTU_IMAGE,UBUNTU_SERIES,UBUNTU_VERSION,APT_PROXY,HTTP_PROXY,HTTPS_PROXY,NO_PROXY,http_proxy,https_proxy,no_proxy \
        "$0" "${BUILD_ARGS[@]}"
fi

cleanup_mounts() {
    local target
    while IFS= read -r target; do
        umount "$target" 2>/dev/null || true
    done < <(findmnt -rn -o TARGET | awk -v p="$WORK_DIR" \
        '$0 == p || index($0, p "/") == 1' | sort -r)
    ! findmnt -rn -o TARGET | awk -v p="$WORK_DIR" \
        '$0 == p || index($0, p "/") == 1 { found=1 } END { exit !found }'
}

on_exit() {
    local rc=$?
    trap - EXIT
    if ! cleanup_mounts; then
        echo "ERROR: busy mounts remain below $WORK_DIR" >&2
        (( rc != 0 )) || rc=1
    fi
    exit "$rc"
}

clean_workdir() {
    [[ "$WORK_DIR" == "${BUILD_OUTPUT_DIR%/}/work/"* ]] ||
        die "refusing to clean work directory outside BUILD_OUTPUT_DIR"
    cleanup_mounts || die "busy mounts remain below $WORK_DIR"
    rm -rf -- "$WORK_DIR"
}

cache_seed() {
    local seed_name="$1" archive_url stage repo
    repo="${SEED_CACHE_ROOT}/${seed_name}"
    [[ -s "${repo}/STRUCTURE" && -d "${repo}/.git" ]] && return
    stage="$(mktemp -d "${SEED_CACHE_ROOT}/.${seed_name}.XXXXXX")"
    archive_url="https://ubuntu-archive-team.ubuntu.com/seeds/${seed_name}.${UBUNTU_SERIES}/"
    info "Cache Canonical ${seed_name}.${UBUNTU_SERIES} seed"
    if ! env http_proxy="${HTTP_PROXY:-}" https_proxy="${HTTPS_PROXY:-}" \
        no_proxy="${NO_PROXY:-}" wget --quiet --mirror --no-parent \
        --no-host-directories --cut-dirs=2 --reject='index.html*' \
        --timeout=30 --tries=3 --retry-connrefused \
        --directory-prefix="$stage" "$archive_url"; then
        rm -rf -- "$stage"
        die "cannot download $archive_url"
    fi
    [[ -s "${stage}/STRUCTURE" ]] || die "incomplete ${seed_name} seed cache"
    git -C "$stage" init --quiet --initial-branch="$UBUNTU_SERIES"
    git -C "$stage" config user.email builder@localhost
    git -C "$stage" config user.name "Ubuntu Image Builder"
    git -C "$stage" add -A
    git -C "$stage" commit --quiet -m "Import Canonical ${seed_name}.${UBUNTU_SERIES} seed"
    rm -rf -- "$repo"
    mv "$stage" "$repo"
}

cache_product_seed() {
    local source="${PROJECT_DIR}/config/ubuntu-image/seeds"
    local repo="${SEED_CACHE_ROOT}/ubuntu" source_hash cached_subject structure_stage
    source_hash="$(sha256sum "${source}/rockchip-server" | awk '{print $1}')"
    cached_subject="$(git -C "$repo" log -1 --format=%s 2>/dev/null || true)"
    [[ "$cached_subject" == "Import Rockchip product seed ${source_hash}" ]] && return
    [[ -s "${repo}/STRUCTURE" && -d "${repo}/.git" ]] ||
        die "Canonical ubuntu seed cache is incomplete"
    install -m 0644 "${source}/rockchip-server" "${repo}/rockchip-server"
    structure_stage="${repo}/.STRUCTURE.rockchip.$$"
    grep -Fvx 'rockchip-server: minimal' "${repo}/STRUCTURE" >"$structure_stage"
    printf 'rockchip-server: minimal\n' >>"$structure_stage"
    mv -f "$structure_stage" "${repo}/STRUCTURE"
    git -C "$repo" add STRUCTURE rockchip-server
    git -C "$repo" commit --quiet --allow-empty \
        -m "Import Rockchip product seed ${source_hash}"
}

install -d -m 2775 "$IMAGES_DIR" "$LOGS_DIR" "$SEED_CACHE_ROOT"
cache_seed ubuntu
cache_seed platform
cache_product_seed
clean_workdir
install -d -m 0755 "$UI_OUTPUT"
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mirror="${UBUNTU_PORTS_MIRROR%/}/"
sed -e "s|@UBUNTU_PORTS_MIRROR@|${mirror}|g" \
    -e "s|@SEED_CACHE_ROOT@|${SEED_CACHE_ROOT}|g" \
    "$DEFINITION_TEMPLATE" >"$DEFINITION"

if [[ "$VARIANT" == desktop ]]; then
    # Reuse the Server seed and account policy. Only the explicit GNOME package
    # list differs; desktop metapackages would pull excluded product payloads.
    desktop_packages="${PROJECT_DIR}/config/ubuntu-image/desktop.packages"
    extra_packages="${WORK_DIR}/desktop-extra-packages.yaml"
    awk 'NF && $1 !~ /^#/ {printf "    - {name: %s}\n", $1}' \
        "$desktop_packages" >"$extra_packages"
    sed -i -e 's/name: ubuntu-server-arm64/name: ubuntu-desktop-arm64/' \
        -e 's/display-name: Ubuntu Server arm64/display-name: Ubuntu GNOME arm64/' \
        -e 's/ubuntu-26.04-server-arm64/ubuntu-26.04-desktop-arm64/g' \
        -e 's/extra-snaps: \[{name: snapd}\]/extra-snaps: [{name: snapd}, {name: bare}, {name: core22}, {name: core24}, {name: gtk-common-themes, channel: latest\/stable}, {name: gnome-46-2404, channel: latest\/stable}, {name: mesa-2404, channel: latest\/stable}, {name: cups, channel: latest\/stable}, {name: chromium, channel: latest\/stable}]/' \
        -e "/^  extra-packages:/r $extra_packages" "$DEFINITION"
fi

info "Build Ubuntu ${UBUNTU_VERSION} ${VARIANT} ARM64 rootfs on ${HOST_ARCH}"
http_proxy="${APT_PROXY:-}" https_proxy="" no_proxy="127.0.0.1,localhost" \
    "$UBUNTU_IMAGE" classic --workdir "$UI_WORK" --output-dir "$UI_OUTPUT" \
    --debug --thru create_chroot "$DEFINITION" 2>&1 |
    tee "${LOGS_DIR}/${IMAGE_BASENAME}-ubuntu-image.log"
[[ -d "${UI_WORK}/chroot/etc/apt/apt.conf.d" ]] ||
    die "ubuntu-image did not create the rootfs APT configuration directory"
install -m 0644 "$APT_POLICY" \
    "${UI_WORK}/chroot/etc/apt/apt.conf.d/99-rockchip-product-policy"
http_proxy="${APT_PROXY:-}" https_proxy="" no_proxy="127.0.0.1,localhost" \
    "$UBUNTU_IMAGE" classic --workdir "$UI_WORK" --output-dir "$UI_OUTPUT" \
    --debug --resume "$DEFINITION" 2>&1 |
    tee -a "${LOGS_DIR}/${IMAGE_BASENAME}-ubuntu-image.log"
cleanup_mounts || die "ubuntu-image left busy mounts below $WORK_DIR"

ROOTFS_TAR="$(find_single_artifact "$UI_OUTPUT" '*.tar.gz' 'rootfs tarball')"
MANIFEST="$(find_single_artifact "$UI_OUTPUT" '*.manifest' 'package manifest')"
FILELIST="$(find_single_artifact "$UI_OUTPUT" '*.filelist' 'file list')"
[[ -s "$ROOTFS_TAR" ]] || die "ubuntu-image created an empty rootfs tarball"
[[ -s "$MANIFEST" ]] || die "ubuntu-image did not create the package manifest"
[[ -s "$FILELIST" ]] || die "ubuntu-image did not create the file list"

install -m 0644 "$ROOTFS_TAR" "${IMAGES_DIR}/${IMAGE_BASENAME}.rootfs.tar.gz"
install -m 0644 "$MANIFEST" "${IMAGES_DIR}/${IMAGE_BASENAME}.manifest"
install -m 0644 "$FILELIST" "${IMAGES_DIR}/${IMAGE_BASENAME}.filelist"
(
    cd "$IMAGES_DIR"
    sha256sum "${IMAGE_BASENAME}.rootfs.tar.gz" >"${IMAGE_BASENAME}.rootfs.tar.gz.sha256"
)
source_commit=unknown
source_dirty=unknown
if [[ -d "${PROJECT_DIR}/.git" ]]; then
    source_commit="$(git -c safe.directory="$PROJECT_DIR" -C "$PROJECT_DIR" rev-parse --verify HEAD)"
    if [[ -n "$(git -c safe.directory="$PROJECT_DIR" -C "$PROJECT_DIR" status --porcelain=v1 --untracked-files=normal)" ]]; then
        source_dirty=yes
    else
        source_dirty=no
    fi
fi
source_tree_sha256="$(cd "$PROJECT_DIR" && {
    {
        printf '%s\0' AGENTS.md README.md build.sh .env.example .gitignore
        find config docs scripts tests package -type f ! -path '*/__pycache__/*' -print0
    } | sort -z | while IFS= read -r -d '' source_file; do
        [[ "$source_file" != config/ubuntu-image/customization* ]] || continue
        sha256sum "$source_file"
    done
} | sha256sum | awk '{print $1}')"
cat >"${IMAGES_DIR}/${IMAGE_BASENAME}.build-info" <<EOF
release=Ubuntu ${UBUNTU_VERSION}
series=${UBUNTU_SERIES}
variant=${VARIANT}
architecture=${ARCHITECTURE}
host.architecture=${HOST_ARCH}
builder=$($UBUNTU_IMAGE --version | head -n1)
mirror=${mirror}
filesystem=tar
source.commit=${source_commit}
source.dirty=${source_dirty}
source.tree_sha256=${source_tree_sha256}
built.at=$(date --iso-8601=seconds)
EOF

tar -tzf "${IMAGES_DIR}/${IMAGE_BASENAME}.rootfs.tar.gz" \
    >"${WORK_DIR}/rootfs.contents"
grep -Eq '^\.?/?etc/os-release$' "${WORK_DIR}/rootfs.contents" ||
    die "rootfs tarball is missing /etc/os-release"
grep -Eq '^\.?/?var/lib/dpkg/status$' "${WORK_DIR}/rootfs.contents" ||
    die "rootfs tarball is missing the dpkg status database"
tar -xOzf "${IMAGES_DIR}/${IMAGE_BASENAME}.rootfs.tar.gz" \
    ./usr/lib/os-release >"${WORK_DIR}/os-release"
grep -Fxq 'ID=ubuntu' "${WORK_DIR}/os-release" ||
    die "rootfs os-release is not Ubuntu"
grep -Fxq "VERSION_CODENAME=${UBUNTU_SERIES}" "${WORK_DIR}/os-release" ||
    die "rootfs os-release does not match ${UBUNTU_SERIES}"
tar -xOzf "${IMAGES_DIR}/${IMAGE_BASENAME}.rootfs.tar.gz" \
    ./etc/apt/sources.list.d/ubuntu.sources >"${WORK_DIR}/ubuntu.sources"
grep -Fq "URIs: ${mirror}" "${WORK_DIR}/ubuntu.sources" ||
    die "rootfs APT sources do not use ${mirror}"
tar -xOzf "${IMAGES_DIR}/${IMAGE_BASENAME}.rootfs.tar.gz" \
    ./var/lib/cloud/seed/nocloud/user-data >"${WORK_DIR}/user-data"
grep -Eq '^[[:space:]]*users:[[:space:]]*\[\][[:space:]]*$' \
    "${WORK_DIR}/user-data" || die "firstboot image must not pre-create a user"
! grep -Eq '^[[:space:]]*(chpasswd|passwd|password|plain_text_passwd|hashed_passwd):' \
    "${WORK_DIR}/user-data" || die "firstboot image contains preset credentials"
tar -xOzf "${IMAGES_DIR}/${IMAGE_BASENAME}.rootfs.tar.gz" ./etc/passwd \
    >"${WORK_DIR}/passwd"
awk -F: '$3 >= 1000 && $3 < 65534 && $7 !~ /(nologin|false)$/ {exit 1}' \
    "${WORK_DIR}/passwd" || die "firstboot rootfs already contains a login account"
grep -q '^openssh-server[[:space:]]' "${IMAGES_DIR}/${IMAGE_BASENAME}.manifest" ||
    die "rootfs manifest does not contain openssh-server"
grep -q '^adbd[[:space:]]' "${IMAGES_DIR}/${IMAGE_BASENAME}.manifest" ||
    die "rootfs manifest does not contain adbd"
"${SCRIPT_DIR}/check-desktop-manifest.sh" "$VARIANT" "${IMAGES_DIR}/${IMAGE_BASENAME}.manifest"

for forbidden in linux-firmware linux-firmware-raspi unattended-upgrades \
        ubuntu-release-upgrader-core thunderbird; do
    ! grep -Eq "^${forbidden}([[:space:]]|-)" \
        "${IMAGES_DIR}/${IMAGE_BASENAME}.manifest" ||
        die "forbidden package was selected by the source seed: $forbidden"
done
! grep -Eq '^libreoffice([[:space:]]|-)' "${IMAGES_DIR}/${IMAGE_BASENAME}.manifest" ||
    die "forbidden LibreOffice package was selected by the source seed"
jq -n \
    --arg schema ubuntu-rootfs-qa-v1 \
    --arg variant "$VARIANT" \
    --arg result pass \
    --arg image "${IMAGE_BASENAME}.rootfs.tar.gz" \
    --arg sha256 "$(awk '{print $1}' "${IMAGES_DIR}/${IMAGE_BASENAME}.rootfs.tar.gz.sha256")" \
    --arg source_tree_sha256 "$source_tree_sha256" \
    '{schema: $schema, result: $result, variant: $variant, image: $image, sha256: $sha256,
      source_tree_sha256: $source_tree_sha256,
      checks: ["rootfs.os-release", "rootfs.dpkg-status", "rootfs.apt-mirror",
               "rootfs.firstboot-no-preset-account", "package.openssh-server", "package.adbd",
               "packages.forbidden-absent", "packages.variant-boundary"]}' \
    >"${IMAGES_DIR}/${IMAGE_BASENAME}.qa.json"
chown "${SUDO_UID:-0}:${SUDO_GID:-0}" "${IMAGES_DIR}/${IMAGE_BASENAME}."*

info "Artifact: ${IMAGES_DIR}/${IMAGE_BASENAME}.rootfs.tar.gz"
info "${VARIANT} rootfs build passed minimal QA"
