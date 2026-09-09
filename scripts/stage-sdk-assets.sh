#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
MODE=stage

usage() {
    cat <<'EOF'
usage: scripts/stage-sdk-assets.sh [--check]

Without an option, copy the SDK kernel Image, DTBs, DT overlays, selected
modules and selected local Debian packages into the Ubuntu platform-asset
directory. --check verifies an existing bundle. Transfer the resulting
directory with the deployment tool used by the build environment.
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
for env_name in BUILD_OUTPUT_DIR SDK_DIR SDK_OUTPUT_DIR SDK_KERNEL_CONFIG \
    SOC_MODEL PLATFORM_ASSET_DIR KERNEL_MODULE_CONFIG \
    KERNEL_CONFIG_REQUIREMENTS LOCAL_DEB_CONFIG; do
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
SDK_DIR="${SDK_DIR:-$(cd "${PROJECT_DIR}/.." && pwd)}"
SDK_OUTPUT_DIR="${SDK_OUTPUT_DIR:-${SDK_DIR}/output}"
SDK_KERNEL_CONFIG="${SDK_KERNEL_CONFIG:-}"
SOC_MODEL="${SOC_MODEL:-}"
PLATFORM_ASSET_DIR="${PLATFORM_ASSET_DIR:-${BUILD_OUTPUT_DIR}/platform-assets/${SOC_MODEL}}"
KERNEL_MODULE_CONFIG="${KERNEL_MODULE_CONFIG:-${PROJECT_DIR}/config/kernel-modules/modules.conf}"
KERNEL_CONFIG_REQUIREMENTS="${KERNEL_CONFIG_REQUIREMENTS:-${PROJECT_DIR}/config/kernel/overlay-root.conf}"
LOCAL_DEB_CONFIG="${LOCAL_DEB_CONFIG:-${PROJECT_DIR}/config/local-debs/packages.conf}"

[[ "$SOC_MODEL" =~ ^[a-z0-9][a-z0-9._-]*$ ]] ||
    die "invalid SOC_MODEL: $SOC_MODEL"
for path in "$BUILD_OUTPUT_DIR" "$PLATFORM_ASSET_DIR"; do
    [[ "$path" == /* && "$path" != *[[:space:]]* ]] ||
        die "build paths must be absolute and contain no whitespace: $path"
done
if [[ "$MODE" == stage ]]; then
    [[ -n "$SDK_KERNEL_CONFIG" ]] ||
        die "SDK_KERNEL_CONFIG must point to the SDK kernel build .config"
    for path in "$SDK_OUTPUT_DIR" "$SDK_KERNEL_CONFIG"; do
        [[ "$path" == /* && "$path" != *[[:space:]]* ]] ||
            die "SDK input paths must be absolute and contain no whitespace: $path"
    done
fi
[[ "$(basename "$PLATFORM_ASSET_DIR")" == "$SOC_MODEL" ]] ||
    die "PLATFORM_ASSET_DIR must end with SOC_MODEL (${SOC_MODEL})"
for tool in awk dpkg-deb find install sha256sum; do
    command -v "$tool" >/dev/null || die "missing staging dependency: $tool"
done

validate_checksums() {
    local root="$1"
    [[ -s "${root}/SHA256SUMS" && ! -L "${root}/SHA256SUMS" ]] ||
        die "missing platform asset checksum list: ${root}/SHA256SUMS"
    awk '{ path=$2; sub(/^\*/, "", path); if (path ~ /^\// || path ~ /(^|\/)\.\.($|\/)/) exit 1 }' \
        "${root}/SHA256SUMS" || die "SHA256SUMS contains an unsafe path"
    (cd "$root" && sha256sum --quiet -c SHA256SUMS) ||
        die "platform asset checksum verification failed: $root"
}

validate_existing_bundle() {
    local root="$1" schema
    [[ -d "$root" && ! -L "$root" ]] ||
        die "platform asset directory is unavailable: $root"
    [[ -s "${root}/.platform-asset-root" &&
       ! -L "${root}/.platform-asset-root" ]] ||
        die "missing platform asset schema marker: $root"
    schema="$(<"${root}/.platform-asset-root")"
    case "$schema" in
        schema=ubuntu-platform-assets-v4) validate_bundle "$root" ;;
        schema=ubuntu-platform-assets-v3) validate_checksums "$root" ;;
        schema=ubuntu-platform-assets-v2) validate_checksums "$root" ;;
        # v1 predates the repository-owned checksum contract. The marker is
        # sufficient only for one-time replacement with the current bundle.
        schema=ubuntu-platform-assets-v1) ;;
        *) die "unsupported platform asset schema: $root" ;;
    esac
}

validate_bundle() {
    local root="$1" release modules_root entry
    [[ -d "$root" && ! -L "$root" ]] ||
        die "platform asset directory is unavailable: $root"
    for entry in .platform-asset-root SHA256SUMS asset-info boot/Image \
        boot/kernel.config kernel-release module-manifest.tsv \
        local-deb-manifest.tsv; do
        [[ -s "${root}/${entry}" && ! -L "${root}/${entry}" ]] ||
            die "missing platform asset: ${root}/${entry}"
    done
    grep -Fxq 'schema=ubuntu-platform-assets-v4' \
        "${root}/.platform-asset-root" ||
        die "unsupported platform asset schema: $root"
    release="$(<"${root}/kernel-release")"
    [[ "$release" =~ ^[0-9][0-9A-Za-z._+-]*$ ]] ||
        die "invalid kernel release: $release"
    modules_root="${root}/modules/lib/modules/${release}"
    [[ -d "$modules_root" && ! -L "$modules_root" ]] ||
        die "module tree does not match kernel release: $release"
    for entry in modules.builtin modules.builtin.modinfo; do
        [[ -s "${modules_root}/${entry}" && ! -L "${modules_root}/${entry}" ]] ||
            die "missing kernel module metadata: ${modules_root}/${entry}"
    done
    "${PROJECT_DIR}/scripts/check-kernel-config.sh" \
        "${root}/boot/kernel.config" "$KERNEL_CONFIG_REQUIREMENTS" >/dev/null
    local module_source module_target autoload module_count=0
    while IFS=$'\t' read -r module_source module_target autoload; do
        [[ "$module_source" != /* && "$module_source" != *..* &&
           "$module_target" == kernel/* && "$module_target" != *..* &&
           "$module_target" == *.ko &&
           "$autoload" =~ ^[A-Za-z0-9_-]*$ ]] ||
            die "invalid module manifest row: ${module_source} ${module_target} ${autoload}"
        [[ -s "${modules_root}/${module_target}" &&
           ! -L "${modules_root}/${module_target}" ]] ||
            die "missing selected kernel module: ${module_target}"
        (( module_count += 1 ))
    done <"${root}/module-manifest.tsv"
    (( module_count > 0 )) || die "module manifest is empty"
    [[ "$(find "$modules_root" -type f -name '*.ko' | wc -l)" -eq "$module_count" ]] ||
        die "unlisted kernel modules are present in the platform assets"
    local deb_source deb_name deb_package deb_version deb_arch deb_purpose
    local deb_path actual deb_count=0
    while IFS=$'\t' read -r deb_source deb_name deb_package deb_version \
            deb_arch deb_purpose; do
        [[ "$deb_source" =~ ^[A-Za-z0-9._+~/-]+$ &&
           "$deb_source" != /* && "$deb_source" != *..* &&
           "$deb_name" =~ ^[A-Za-z0-9._+~-]+\.deb$ &&
           "$deb_package" =~ ^[a-z0-9][a-z0-9+.-]*$ &&
           "$deb_version" =~ ^[A-Za-z0-9.+:~_-]+$ &&
           "$deb_arch" =~ ^(arm64|all)$ &&
           "$deb_purpose" =~ ^[a-z0-9][a-z0-9._-]*$ ]] ||
            die "invalid local DEB manifest row: ${deb_source} ${deb_name}"
        deb_path="${root}/debs/${deb_name}"
        [[ -s "$deb_path" && ! -L "$deb_path" ]] ||
            die "missing selected local DEB: ${deb_name}"
        actual="$(dpkg-deb -f "$deb_path" Package)"$'\t'
        actual+="$(dpkg-deb -f "$deb_path" Version)"$'\t'
        actual+="$(dpkg-deb -f "$deb_path" Architecture)"
        [[ "$actual" == "${deb_package}"$'\t'"${deb_version}"$'\t'"${deb_arch}" ]] ||
            die "local DEB metadata changed: ${deb_name}"
        (( deb_count += 1 ))
    done <"${root}/local-deb-manifest.tsv"
    (( deb_count > 0 )) || die "local DEB manifest is empty"
    [[ "$(find "${root}/debs" -maxdepth 1 -type f -name '*.deb' | wc -l)" -eq "$deb_count" ]] ||
        die "unlisted Debian packages are present in the platform assets"
    find "${root}/boot" -maxdepth 1 -type f -name '*.dtb' -print -quit |
        grep -q . || die "platform assets contain no base DTB"
    validate_checksums "$root"
}

stage_bundle() {
    local source_boot source_modules source_module_root release parent stage
    local previous source_commit module_relative install_subdir autoload_module
    local module_source module_target deb_pattern expected_arch deb_purpose
    local pattern_dir pattern_name deb_source deb_name deb_package deb_version
    local deb_arch
    local -a releases=() dt_inputs=()
    local -a deb_matches=()

    source_boot="${SDK_OUTPUT_DIR}/extlinux"
    source_modules="${SDK_OUTPUT_DIR}/kernel-modules/lib/modules"
    [[ -s "${source_boot}/Image" ]] ||
        die "missing SDK kernel image: ${source_boot}/Image"
    mapfile -d '' -t dt_inputs < <(
        find "$source_boot" -maxdepth 1 -type f \
            \( -name '*.dtb' -o -name '*.dtbo' \) -print0 | sort -z
    )
    (( ${#dt_inputs[@]} > 0 )) ||
        die "no SDK DTB or DT overlay found in $source_boot"
    mapfile -d '' -t releases < <(
        find "$source_modules" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z
    )
    (( ${#releases[@]} == 1 )) ||
        die "expected one SDK module release in ${source_modules}, found ${#releases[@]}"
    release="$(basename "${releases[0]}")"
    [[ "$release" =~ ^[0-9][0-9A-Za-z._+-]*$ ]] ||
        die "invalid SDK kernel release: $release"
    [[ -s "$KERNEL_MODULE_CONFIG" ]] ||
        die "missing kernel module selection: $KERNEL_MODULE_CONFIG"
    # Repository-owned configuration defining MODULE_ENTRIES.
    # shellcheck disable=SC1090
    source "$KERNEL_MODULE_CONFIG"
    declare -p MODULE_ENTRIES >/dev/null 2>&1 ||
        die "MODULE_ENTRIES must be an array: $KERNEL_MODULE_CONFIG"
    (( ${#MODULE_ENTRIES[@]} > 0 )) ||
        die "MODULE_ENTRIES is empty: $KERNEL_MODULE_CONFIG"
    [[ -s "$LOCAL_DEB_CONFIG" ]] ||
        die "missing local DEB selection: $LOCAL_DEB_CONFIG"
    # Repository-owned configuration defining DEB_ENTRIES.
    # shellcheck disable=SC1090
    source "$LOCAL_DEB_CONFIG"
    declare -p DEB_ENTRIES >/dev/null 2>&1 ||
        die "DEB_ENTRIES must be an array: $LOCAL_DEB_CONFIG"
    (( ${#DEB_ENTRIES[@]} > 0 )) ||
        die "DEB_ENTRIES is empty: $LOCAL_DEB_CONFIG"
    source_module_root="${releases[0]}/kernel"
    [[ -s "$SDK_KERNEL_CONFIG" && ! -L "$SDK_KERNEL_CONFIG" ]] ||
        die "missing SDK kernel config: $SDK_KERNEL_CONFIG"
    "${PROJECT_DIR}/scripts/check-kernel-config.sh" \
        "$SDK_KERNEL_CONFIG" "$KERNEL_CONFIG_REQUIREMENTS"
    for entry in modules.builtin modules.builtin.modinfo; do
        [[ -s "${releases[0]}/${entry}" && ! -L "${releases[0]}/${entry}" ]] ||
            die "missing SDK module metadata: ${releases[0]}/${entry}"
    done

    parent="$(dirname "$PLATFORM_ASSET_DIR")"
    install -d -m 2775 "$parent"
    stage="$(mktemp -d "${parent}/.${SOC_MODEL}.stage.XXXXXX")"
    chmod 2750 "$stage"
    previous="${parent}/.${SOC_MODEL}.previous.$$"
    cleanup_stage() { rm -rf -- "$stage" "$previous"; }
    trap cleanup_stage EXIT

    install -d -m 0755 "$stage/boot" "$stage/modules/lib/modules" \
        "$stage/debs"
    install -m 0644 "${source_boot}/Image" "$stage/boot/Image"
    install -m 0644 "${dt_inputs[@]}" "$stage/boot/"
    install -m 0644 "$SDK_KERNEL_CONFIG" "$stage/boot/kernel.config"
    if [[ -s "${source_boot}/extlinux.conf" ]]; then
        install -m 0644 "${source_boot}/extlinux.conf" \
            "$stage/boot/extlinux.conf"
    fi
    install -d -m 0755 "$stage/modules/lib/modules/$release"
    install -m 0644 "${releases[0]}/modules.builtin" \
        "${releases[0]}/modules.builtin.modinfo" \
        "$stage/modules/lib/modules/$release/"
    : >"$stage/module-manifest.tsv"
    declare -A module_targets=()
    for entry in "${MODULE_ENTRIES[@]}"; do
        IFS='|' read -r module_relative install_subdir autoload_module <<<"$entry"
        [[ "$module_relative" != /* && "$module_relative" != *..* &&
           "$module_relative" == *.ko &&
           "$install_subdir" == kernel/* && "$install_subdir" != *..* &&
           "$autoload_module" =~ ^[A-Za-z0-9_-]*$ ]] ||
            die "invalid MODULE_ENTRIES item: $entry"
        module_source="${source_module_root}/${module_relative}"
        [[ -s "$module_source" && ! -L "$module_source" ]] ||
            die "missing selected SDK kernel module: $module_source"
        module_target="${install_subdir}/$(basename "$module_relative")"
        [[ ! -v "module_targets[$module_target]" ]] ||
            die "duplicate kernel module target: $module_target"
        module_targets["$module_target"]=1
        install -D -m 0644 "$module_source" \
            "$stage/modules/lib/modules/$release/$module_target"
        printf '%s\t%s\t%s\n' "$module_relative" "$module_target" \
            "$autoload_module" >>"$stage/module-manifest.tsv"
    done
    : >"$stage/local-deb-manifest.tsv"
    declare -A deb_targets=()
    for entry in "${DEB_ENTRIES[@]}"; do
        IFS='|' read -r deb_pattern expected_arch deb_purpose <<<"$entry"
        [[ "$deb_pattern" =~ ^[A-Za-z0-9._+?*~/-]+$ &&
           "$deb_pattern" != /* && "$deb_pattern" != *..* &&
           "$deb_pattern" == */*.deb &&
           "$expected_arch" =~ ^(arm64|all)$ &&
           "$deb_purpose" =~ ^[a-z0-9][a-z0-9._-]*$ ]] ||
            die "invalid DEB_ENTRIES item: $entry"
        pattern_dir="${deb_pattern%/*}"
        pattern_name="${deb_pattern##*/}"
        [[ "$pattern_dir" != *'*'* && "$pattern_dir" != *'?'* &&
           "$pattern_dir" != *'['* ]] ||
            die "local DEB directory cannot contain a pattern: $deb_pattern"
        [[ -d "${SDK_OUTPUT_DIR}/${pattern_dir}" ]] ||
            die "missing local DEB source directory: ${SDK_OUTPUT_DIR}/${pattern_dir}"
        mapfile -d '' -t deb_matches < <(
            find "${SDK_OUTPUT_DIR}/${pattern_dir}" -maxdepth 1 -type f \
                -name "$pattern_name" -print0 | sort -z
        )
        (( ${#deb_matches[@]} == 1 )) ||
            die "local DEB entry must match exactly one file: ${deb_pattern} (found ${#deb_matches[@]})"
        deb_source="${deb_matches[0]}"
        deb_name="$(basename "$deb_source")"
        [[ ! -v "deb_targets[$deb_name]" ]] ||
            die "duplicate local DEB target: $deb_name"
        deb_targets["$deb_name"]=1
        deb_package="$(dpkg-deb -f "$deb_source" Package)"
        deb_version="$(dpkg-deb -f "$deb_source" Version)"
        deb_arch="$(dpkg-deb -f "$deb_source" Architecture)"
        [[ "$deb_package" =~ ^[a-z0-9][a-z0-9+.-]*$ &&
           "$deb_version" =~ ^[A-Za-z0-9.+:~_-]+$ ]] ||
            die "invalid Debian package metadata: $deb_source"
        [[ "$deb_arch" == "$expected_arch" ]] ||
            die "local DEB architecture mismatch: ${deb_name} is ${deb_arch}, expected ${expected_arch}"
        install -m 0644 "$deb_source" "$stage/debs/$deb_name"
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
            "${deb_source#"${SDK_OUTPUT_DIR%/}/"}" "$deb_name" \
            "$deb_package" "$deb_version" "$deb_arch" "$deb_purpose" \
            >>"$stage/local-deb-manifest.tsv"
    done
    printf '%s\n' "$release" >"$stage/kernel-release"
    printf 'schema=ubuntu-platform-assets-v4\n' >"$stage/.platform-asset-root"

    source_commit=unknown
    if git -C "$SDK_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        source_commit="$(git -C "$SDK_DIR" rev-parse --verify HEAD)"
    fi
    cat >"$stage/asset-info" <<EOF
schema=ubuntu-platform-assets-v4
soc=${SOC_MODEL}
kernel.release=${release}
sdk.commit=${source_commit}
sdk.boot.source=output/extlinux
sdk.kernel.config=${SDK_KERNEL_CONFIG#"${SDK_DIR%/}/"}
sdk.modules.source=output/kernel-modules/lib/modules/${release}
sdk.debs.source=output
staged.at=$(date --iso-8601=seconds)
EOF
    (
        cd "$stage"
        # SHA256SUMS is explicitly excluded from the find input.
        # shellcheck disable=SC2094
        find . -type f ! -name SHA256SUMS -print0 | sort -z |
            xargs -0 sha256sum >SHA256SUMS
    )
    validate_bundle "$stage"

    if [[ -e "$PLATFORM_ASSET_DIR" ]]; then
        validate_existing_bundle "$PLATFORM_ASSET_DIR"
        mv "$PLATFORM_ASSET_DIR" "$previous"
    fi
    mv "$stage" "$PLATFORM_ASSET_DIR"
    rm -rf -- "$previous"
    trap - EXIT
    info "Platform assets staged: $PLATFORM_ASSET_DIR"
    info "Kernel release: $release"
}

case "$MODE" in
    stage) stage_bundle ;;
    check)
        validate_bundle "$PLATFORM_ASSET_DIR"
        info "Platform assets are valid: $PLATFORM_ASSET_DIR"
        ;;
esac
