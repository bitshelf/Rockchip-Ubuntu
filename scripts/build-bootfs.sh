#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
MODE=build

usage() {
    cat <<'EOF'
usage: scripts/build-bootfs.sh [--check]

Build an independent ext4 bootfs image from a verified platform-asset bundle.
--check validates an existing image and its SHA256 sidecar without mounting it.
EOF
}

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

host_arch() {
    case "$(uname -m)" in
        aarch64|arm64) echo arm64 ;;
        x86_64|amd64) echo amd64 ;;
        *) die "unsupported build-host architecture: $(uname -m)" ;;
    esac
}

case "${1:-}" in
    "") ;;
    --check) MODE=check; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
esac
(( $# == 0 )) || { usage >&2; exit 2; }

declare -A CALLER_ENV=()
for env_name in BUILD_OUTPUT_DIR SOC_MODEL PLATFORM_ASSET_DIR BOOTFS_CONFIG \
    BOOTFS_TEMPLATE BOOTFS_OUTPUT BOOTFS_INITRD BOOTFS_SIZE_MB BOOTFS_LABEL \
    BOOTFS_BASE_DTB BOOTFS_INSTALLED_DTB BOOTFS_TIMEOUT BOOTFS_CMDLINE; do
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
    export "${env_name?}"
done

HOST_ARCH="$(host_arch)"
if [[ "$HOST_ARCH" == arm64 ]]; then
    BUILD_OUTPUT_DIR="${BUILD_OUTPUT_DIR:-/var/lib/ubuntu-ci/build}"
else
    BUILD_OUTPUT_DIR="${BUILD_OUTPUT_DIR:-${PROJECT_DIR}/build}"
fi
SOC_MODEL="${SOC_MODEL:-rk3576}"
PLATFORM_ASSET_DIR="${PLATFORM_ASSET_DIR:-${BUILD_OUTPUT_DIR}/platform-assets/${SOC_MODEL}}"
BOOTFS_CONFIG="${BOOTFS_CONFIG:-${PROJECT_DIR}/config/bootfs/bootfs.conf}"
BOOTFS_TEMPLATE="${BOOTFS_TEMPLATE:-${PROJECT_DIR}/config/bootfs/extlinux.conf.in}"

# Values selected by the caller or .env override repository defaults.
declare -A POLICY_ENV=()
for env_name in BOOTFS_SIZE_MB BOOTFS_LABEL BOOTFS_BASE_DTB \
    BOOTFS_INSTALLED_DTB BOOTFS_TIMEOUT BOOTFS_CMDLINE; do
    if [[ -v "$env_name" ]]; then
        POLICY_ENV["$env_name"]="${!env_name}"
    fi
done
[[ -s "$BOOTFS_CONFIG" ]] || die "missing bootfs policy: $BOOTFS_CONFIG"
# Repository-owned policy defining scalar values and BOOTFS_ENABLED_OVERLAYS.
# shellcheck disable=SC1090
source "$BOOTFS_CONFIG"
for env_name in "${!POLICY_ENV[@]}"; do
    printf -v "$env_name" '%s' "${POLICY_ENV[$env_name]}"
done

[[ "$(declare -p BOOTFS_ENABLED_OVERLAYS 2>/dev/null || true)" == 'declare -a '* ]] ||
    die "BOOTFS_ENABLED_OVERLAYS must be an array: $BOOTFS_CONFIG"
BOOTFS_OUTPUT="${BOOTFS_OUTPUT:-${BUILD_OUTPUT_DIR}/images/bootfs-${SOC_MODEL}.img}"
BOOTFS_INITRD="${BOOTFS_INITRD:-}"

[[ "$SOC_MODEL" =~ ^[a-z0-9][a-z0-9._-]*$ ]] ||
    die "invalid SOC_MODEL: $SOC_MODEL"
for path in "$BUILD_OUTPUT_DIR" "$PLATFORM_ASSET_DIR" "$BOOTFS_OUTPUT"; do
    [[ "$path" == /* && "$path" != *[[:space:]]* ]] ||
        die "build paths must be absolute and contain no whitespace: $path"
done
[[ "$BOOTFS_SIZE_MB" =~ ^[1-9][0-9]*$ ]] ||
    die "invalid BOOTFS_SIZE_MB: $BOOTFS_SIZE_MB"
(( BOOTFS_SIZE_MB >= 64 )) || die "BOOTFS_SIZE_MB must be at least 64"
[[ "$BOOTFS_LABEL" =~ ^[A-Za-z0-9._-]{1,16}$ ]] ||
    die "invalid ext4 label: $BOOTFS_LABEL"
for name in "$BOOTFS_BASE_DTB" "$BOOTFS_INSTALLED_DTB"; do
    [[ "$name" =~ ^[A-Za-z0-9._+-]+\.dtb$ ]] ||
        die "invalid DTB filename: $name"
done
[[ "$BOOTFS_TIMEOUT" =~ ^[0-9]+$ ]] ||
    die "invalid BOOTFS_TIMEOUT: $BOOTFS_TIMEOUT"
[[ -n "$BOOTFS_CMDLINE" && "$BOOTFS_CMDLINE" != *$'\n'* &&
   "$BOOTFS_CMDLINE" != *'|'* ]] || die "invalid BOOTFS_CMDLINE"
for tool in awk debugfs dumpe2fs e2fsck fdtget sha256sum stat; do
    command -v "$tool" >/dev/null || die "missing bootfs validation dependency: $tool"
done

extract_image_file() {
    local image="$1" image_path="$2" destination="$3" output inode
    inode="$(debugfs -R "stat ${image_path}" "$image" 2>&1)" ||
        die "cannot stat ${image_path} in $image: $inode"
    grep -Eq '^Inode:.*Type: regular' <<<"$inode" ||
        die "bootfs path is not a regular file: $image_path"
    grep -Eq 'User:[[:space:]]+0[[:space:]]+Group:[[:space:]]+0' <<<"$inode" ||
        die "bootfs file is not owned by root:root: $image_path"
    output="$(debugfs -R "dump -p ${image_path} ${destination}" "$image" 2>&1)" ||
        die "cannot extract ${image_path} from $image: $output"
    [[ -s "$destination" ]] || die "empty bootfs file: $image_path"
}

validate_bootfs() {
    local image="$1" checksum_file="$2" check_dir label features fs_bytes
    local extlinux manifest path source_hash image_hash extracted overlay
    local manifest_count=0
    local -a referenced_paths=()

    [[ -s "$image" && ! -L "$image" ]] || die "missing bootfs image: $image"
    [[ -s "$checksum_file" && ! -L "$checksum_file" ]] ||
        die "missing bootfs checksum: $checksum_file"
    (cd "$(dirname "$image")" && sha256sum --quiet -c "$(basename "$checksum_file")") ||
        die "bootfs image checksum verification failed: $image"
    e2fsck -fn "$image" >/dev/null 2>&1 || die "bootfs ext4 check failed: $image"
    label="$(dumpe2fs -h "$image" 2>/dev/null |
        awk -F: '$1 ~ /^Filesystem volume name/ {sub(/^[[:space:]]+/, "", $2); print $2}')"
    [[ "$label" == "$BOOTFS_LABEL" ]] ||
        die "bootfs label is ${label}, expected ${BOOTFS_LABEL}"
    features="$(dumpe2fs -h "$image" 2>/dev/null |
        awk -F: '$1 ~ /^Filesystem features/ {print $2}')"
    [[ " $features " != *' orphan_file '* ]] ||
        die "bootfs uses orphan_file, which is incompatible with the target U-Boot"
    fs_bytes="$(stat -c %s "$image")"
    [[ "$fs_bytes" -eq $((BOOTFS_SIZE_MB * 1024 * 1024)) ]] ||
        die "bootfs size is ${fs_bytes}, expected $((BOOTFS_SIZE_MB * 1024 * 1024))"

    check_dir="$(mktemp -d)"
    trap 'rm -rf -- "$check_dir"' RETURN
    extlinux="${check_dir}/extlinux.conf"
    manifest="${check_dir}/bootfs.manifest.tsv"
    extract_image_file "$image" /extlinux/extlinux.conf "$extlinux"
    extract_image_file "$image" /bootfs.manifest.tsv "$manifest"
    grep -Eq '^[[:space:]]*label[[:space:]]+[^[:space:]]+' "$extlinux" ||
        die "extlinux.conf has no boot label"
    grep -Eq '^[[:space:]]*append[[:space:]]+.*root=' "$extlinux" ||
        die "extlinux.conf has no root= command line"
    mapfile -t referenced_paths < <(
        awk '{key=tolower($1)}
             key == "linux" || key == "kernel" || key == "initrd" || key == "fdt" {print $2}
             key == "fdtoverlays" {for (i=2; i<=NF; i++) print $i}' "$extlinux"
    )
    (( ${#referenced_paths[@]} >= 2 )) ||
        die "extlinux.conf does not reference a kernel and DTB"
    for path in "${referenced_paths[@]}"; do
        [[ "$path" =~ ^/[A-Za-z0-9._+/-]+$ && "$path" != *..* ]] ||
            die "unsafe extlinux path: $path"
        extracted="${check_dir}/ref-$(printf '%s' "$path" | sha256sum | awk '{print $1}')"
        extract_image_file "$image" "$path" "$extracted"
        case "$path" in
            *.dtb|*.dtbo) fdtget -l "$extracted" / >/dev/null ||
                die "invalid flattened device tree in bootfs: $path" ;;
        esac
    done
    while IFS=$'\t' read -r path source_hash; do
        [[ "$path" =~ ^/[A-Za-z0-9._+/-]+$ && "$path" != *..* &&
           "$source_hash" =~ ^[0-9a-f]{64}$ ]] ||
            die "invalid bootfs manifest row: ${path} ${source_hash}"
        extracted="${check_dir}/manifest-$(printf '%s' "$path" | sha256sum | awk '{print $1}')"
        extract_image_file "$image" "$path" "$extracted"
        image_hash="$(sha256sum "$extracted" | awk '{print $1}')"
        [[ "$image_hash" == "$source_hash" ]] ||
            die "bootfs manifest checksum mismatch: $path"
        case "$path" in
            /overlays/*.dtbo)
                overlay="$(basename "$path")"
                fdtget -l "$extracted" / >/dev/null ||
                    die "invalid DT overlay in bootfs: $overlay"
                ;;
        esac
        (( manifest_count += 1 ))
    done <"$manifest"
    (( manifest_count >= 3 )) || die "bootfs manifest is incomplete"
    trap - RETURN
    rm -rf -- "$check_dir"
}

checksum_file="${BOOTFS_OUTPUT}.sha256"
if [[ "$MODE" == check ]]; then
    validate_bootfs "$BOOTFS_OUTPUT" "$checksum_file"
    info "Bootfs image is valid: $BOOTFS_OUTPUT"
    exit 0
fi

[[ -s "$BOOTFS_TEMPLATE" ]] || die "missing extlinux template: $BOOTFS_TEMPLATE"
if [[ -n "$BOOTFS_INITRD" ]]; then
    [[ "$BOOTFS_INITRD" == /* && -s "$BOOTFS_INITRD" && ! -L "$BOOTFS_INITRD" ]] ||
        die "BOOTFS_INITRD must be an absolute regular file: $BOOTFS_INITRD"
fi
for tool in fakeroot find install mkfs.ext4 truncate; do
    command -v "$tool" >/dev/null || die "missing bootfs build dependency: $tool"
done

[[ -s "${PLATFORM_ASSET_DIR}/boot/Image" ]] ||
    die "missing staged kernel Image: ${PLATFORM_ASSET_DIR}/boot/Image"
[[ -s "${PLATFORM_ASSET_DIR}/boot/${BOOTFS_BASE_DTB}" ]] ||
    die "missing configured base DTB: ${PLATFORM_ASSET_DIR}/boot/${BOOTFS_BASE_DTB}"
"${SCRIPT_DIR}/stage-sdk-assets.sh" --check
fdtget -l "${PLATFORM_ASSET_DIR}/boot/${BOOTFS_BASE_DTB}" / >/dev/null ||
    die "configured base DTB is invalid: $BOOTFS_BASE_DTB"

images_dir="$(dirname "$BOOTFS_OUTPUT")"
work_parent="${BUILD_OUTPUT_DIR}/work/bootfs"
install -d -m 2775 "$images_dir" "$work_parent"
work_dir="$(mktemp -d "${work_parent}/.${SOC_MODEL}.XXXXXX")"
image_stage="$(mktemp "${images_dir}/.$(basename "$BOOTFS_OUTPUT").XXXXXX")"
cleanup() { rm -rf -- "$work_dir"; rm -f -- "$image_stage"; }
trap cleanup EXIT
install -d -m 0755 "$work_dir/root/extlinux" "$work_dir/root/dtb" \
    "$work_dir/root/overlays"
install -m 0644 "${PLATFORM_ASSET_DIR}/boot/Image" "$work_dir/root/Image"
install -m 0644 "${PLATFORM_ASSET_DIR}/boot/${BOOTFS_BASE_DTB}" \
    "$work_dir/root/dtb/${BOOTFS_INSTALLED_DTB}"

mapfile -d '' -t overlay_sources < <(
    find "${PLATFORM_ASSET_DIR}/boot" -maxdepth 1 -type f -name '*.dtbo' \
        -print0 | sort -z
)
for overlay in "${overlay_sources[@]}"; do
    fdtget -l "$overlay" / >/dev/null || die "invalid staged DT overlay: $overlay"
    install -m 0644 "$overlay" "$work_dir/root/overlays/"
done

overlay_line=""
declare -A enabled_names=()
for overlay in "${BOOTFS_ENABLED_OVERLAYS[@]}"; do
    [[ "$overlay" =~ ^[A-Za-z0-9._+-]+\.dtbo$ ]] ||
        die "invalid enabled overlay name: $overlay"
    [[ ! -v "enabled_names[$overlay]" ]] || die "duplicate enabled overlay: $overlay"
    enabled_names["$overlay"]=1
    [[ -s "$work_dir/root/overlays/$overlay" ]] ||
        die "enabled overlay is not present in platform assets: $overlay"
    if [[ -n "$overlay_line" ]]; then
        overlay_line+=' '
    else
        overlay_line='    fdtoverlays '
    fi
    overlay_line+="/overlays/${overlay}"
done
initrd_line=""
if [[ -n "$BOOTFS_INITRD" ]]; then
    install -m 0644 "$BOOTFS_INITRD" "$work_dir/root/initrd.img"
    initrd_line="    initrd /initrd.img"
fi
awk -v timeout="$BOOTFS_TIMEOUT" -v dtb_name="$BOOTFS_INSTALLED_DTB" \
    -v cmdline="$BOOTFS_CMDLINE" -v initrd_line="$initrd_line" \
    -v overlay_line="$overlay_line" '
        $0 == "@INITRD_LINE@" { if (initrd_line != "") print initrd_line; next }
        $0 == "@OVERLAY_LINE@" { if (overlay_line != "") print overlay_line; next }
        { gsub(/@TIMEOUT@/, timeout); gsub(/@DTB_NAME@/, dtb_name);
          gsub(/@CMDLINE@/, cmdline); print }
    ' "$BOOTFS_TEMPLATE" >"$work_dir/root/extlinux/extlinux.conf"

manifest="$work_dir/root/bootfs.manifest.tsv"
: >"$manifest"
while IFS= read -r -d '' path; do
    relative="/${path#"$work_dir/root/"}"
    [[ "$relative" != /bootfs.manifest.tsv ]] || continue
    printf '%s\t%s\n' "$relative" "$(sha256sum "$path" | awk '{print $1}')" \
        >>"$manifest"
done < <(find "$work_dir/root" -type f -print0 | sort -z)

truncate -s "${BOOTFS_SIZE_MB}M" "$image_stage"
# Positional parameters are expanded by the inner fakeroot shell.
# shellcheck disable=SC2016
fakeroot -- sh -eu -c '
    chown -R 0:0 "$1"
    exec mkfs.ext4 -q -F -L "$3" -O "^orphan_file" -d "$1" "$2"
' sh "$work_dir/root" "$image_stage" "$BOOTFS_LABEL"
mv -f -- "$image_stage" "$BOOTFS_OUTPUT"
(
    cd "$images_dir"
    sha256sum "$(basename "$BOOTFS_OUTPUT")" >"$(basename "$checksum_file")"
)
cat >"${BOOTFS_OUTPUT}.build-info" <<EOF
schema=ubuntu-bootfs-v1
soc=${SOC_MODEL}
platform.assets=${PLATFORM_ASSET_DIR}
platform.assets.sha256=$(sha256sum "${PLATFORM_ASSET_DIR}/SHA256SUMS" | awk '{print $1}')
kernel.release=$(<"${PLATFORM_ASSET_DIR}/kernel-release")
base.dtb=${BOOTFS_BASE_DTB}
enabled.overlays=${BOOTFS_ENABLED_OVERLAYS[*]:-}
initrd=$([[ -n "$BOOTFS_INITRD" ]] && echo yes || echo no)
filesystem=ext4
filesystem.label=${BOOTFS_LABEL}
filesystem.size_mb=${BOOTFS_SIZE_MB}
EOF
chmod 0644 "$BOOTFS_OUTPUT" "$checksum_file" "${BOOTFS_OUTPUT}.build-info"
validate_bootfs "$BOOTFS_OUTPUT" "$checksum_file"
trap - EXIT
rm -rf -- "$work_dir"
info "Bootfs image built and verified: $BOOTFS_OUTPUT"
