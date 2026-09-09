#!/usr/bin/env bash
set -Eeuo pipefail
umask 0002

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG="${LOCAL_DEB_PREPARE_CONFIG:-${PROJECT_DIR}/config/local-debs/prepare.conf}"
requested="${1:-all}"

die() { echo "ERROR: $*" >&2; exit 1; }

if [[ -f "$PROJECT_DIR/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "$PROJECT_DIR/.env"
    set +a
fi
SDK_DIR="${SDK_DIR:-$(cd "$PROJECT_DIR/.." && pwd)}"
SDK_OUTPUT_DIR="${SDK_OUTPUT_DIR:-$SDK_DIR/output}"
[[ "$SDK_DIR" == /* && -d "$SDK_DIR/debian/packages/arm64" &&
   "$SDK_OUTPUT_DIR" == /* && "$SDK_OUTPUT_DIR" != / && -s "$CONFIG" ]] ||
    die "invalid SDK_DIR, SDK_OUTPUT_DIR or prepare config"
# shellcheck disable=SC1090
source "$CONFIG"
declare -p LOCAL_DEB_COPY_ENTRIES LOCAL_DATA_DEB_ENTRIES >/dev/null 2>&1 ||
    die "prepare config must define both local DEB arrays"

find_package() {
    local package="$1" candidate
    local -a matches=()
    while IFS= read -r -d '' candidate; do
        [[ "$(dpkg-deb -f "$candidate" Package 2>/dev/null || true)" == "$package" ]] &&
            matches+=("$candidate")
    done < <(find "$SDK_DIR/debian/packages/arm64" -type f -name '*.deb' -print0 | sort -z)
    (( ${#matches[@]} == 1 )) ||
        die "expected one SDK package named $package, found ${#matches[@]}"
    printf '%s\n' "${matches[0]}"
}

selected=0
for entry in "${LOCAL_DEB_COPY_ENTRIES[@]}"; do
    IFS='|' read -r package destination extra <<<"$entry"
    [[ -n "$package" && "$destination" =~ ^[A-Za-z0-9._+-]+$ && -z "${extra:-}" ]] ||
        die "invalid copy entry: $entry"
    [[ "$requested" == all || "$requested" == "$package" ]] || continue
    selected=1
    source_deb="$(find_package "$package")"
    install -D -m 0644 "$source_deb" "$SDK_OUTPUT_DIR/$destination/$(basename "$source_deb")"
done

for entry in "${LOCAL_DATA_DEB_ENTRIES[@]}"; do
    IFS='|' read -r package architecture source_env name_env install_dir destination description validator extra <<<"$entry"
    [[ -z "${extra:-}" && "$source_env" =~ ^[A-Z][A-Z0-9_]*$ &&
       "$name_env" =~ ^[A-Z][A-Z0-9_]*$ && "$install_dir" == /* &&
       "$install_dir" != *..* && "$destination" =~ ^[A-Za-z0-9._+-]+$ ]] ||
        die "invalid data package entry: $entry"
    [[ "$requested" == all || "$requested" == "$package" ]] || continue
    selected=1
    source_file="${!source_env:-}"
    install_name="${!name_env:-}"
    [[ "$source_file" == /* && -s "$source_file" &&
       "$install_name" =~ ^[A-Za-z0-9._+-]+$ ]] ||
        die "set $source_env and $name_env for $package"
    hash="$(sha256sum "$source_file" | awk '{print $1}')"
    output="$SDK_OUTPUT_DIR/$destination/${package}_1.0+${hash:0:12}_${architecture}.deb"
    "$SCRIPT_DIR/build-data-deb.sh" \
        --package "$package" --version "1.0+${hash:0:12}" \
        --architecture "$architecture" --description "$description" \
        --validator "$validator" --file "$source_file:$install_dir/$install_name:0644" \
        --output "$output" >/dev/null
    printf '%s=%s\n' "$package" "$(basename "$output")"
done
(( selected == 1 )) || die "unknown local package: $requested"
