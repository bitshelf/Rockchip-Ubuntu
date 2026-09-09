#!/usr/bin/env bash
set -Eeuo pipefail

package= version= architecture= description= output= validator=
declare -a files=()

die() { echo "ERROR: $*" >&2; exit 1; }
usage() {
    echo "usage: $0 --package NAME --version VERSION --architecture ARCH --description TEXT --file SOURCE:TARGET[:MODE] [--validator json] --output FILE.deb" >&2
    exit 2
}

while (( $# )); do
    case "$1" in
        --package|--version|--architecture|--description|--output|--validator)
            (( $# >= 2 )) || usage
            option="${1#--}"
            printf -v "$option" '%s' "$2"
            shift 2
            ;;
        --file)
            (( $# >= 2 )) || usage
            files+=("$2")
            shift 2
            ;;
        -h|--help) usage ;;
        *) usage ;;
    esac
done

[[ "$package" =~ ^[a-z0-9][a-z0-9+.-]*$ &&
   "$version" =~ ^[A-Za-z0-9.+:~_-]+$ &&
   "$architecture" =~ ^(all|arm64)$ &&
   -n "$description" && "$output" == /* && "$output" == *.deb &&
   ${#files[@]} -gt 0 ]] || usage
command -v dpkg-deb >/dev/null || die "missing dpkg-deb"
[[ -z "$validator" || "$validator" == json ]] || die "unknown validator: $validator"
[[ "$validator" != json ]] || command -v jq >/dev/null || die "missing jq"

work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
root="$work/root"
install -d -m 0755 "$root/DEBIAN" "$(dirname "$output")"
cat >"$root/DEBIAN/control" <<EOF
Package: ${package}
Version: ${version}
Architecture: ${architecture}
Maintainer: Ubuntu image CI <root@localhost>
Description: ${description}
 Repository-generated data package.
EOF

for entry in "${files[@]}"; do
    IFS=: read -r source target mode extra <<<"$entry"
    [[ -z "${extra:-}" && "$source" == /* && -s "$source" && ! -L "$source" &&
       "$target" == /* && "$target" != *..* ]] || die "invalid file entry: $entry"
    mode="${mode:-0644}"
    [[ "$mode" =~ ^0[0-7]{3}$ ]] || die "invalid file mode: $mode"
    [[ "$validator" != json ]] || jq -e 'type == "object"' "$source" >/dev/null ||
        die "invalid JSON data: $source"
    install -D -m "$mode" "$source" "$root$target"
done

dpkg-deb --build --root-owner-group "$root" "$output" >/dev/null
[[ "$(dpkg-deb -f "$output" Package)" == "$package" ]] ||
    die "unexpected package output: $output"
printf '%s\n' "$output"
