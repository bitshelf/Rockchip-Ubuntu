#!/usr/bin/env bash
set -Eeuo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }

[[ $# -eq 2 ]] || die "usage: $0 <platform-asset-directory> <purpose>"
asset_dir="$1"
purpose="$2"
manifest="${asset_dir}/local-deb-manifest.tsv"

[[ "$asset_dir" == /* && -d "$asset_dir" && ! -L "$asset_dir" ]] ||
    die "invalid platform asset directory: $asset_dir"
[[ "$purpose" =~ ^[a-z0-9][a-z0-9._-]*$ ]] || die "invalid purpose: $purpose"
[[ -s "$manifest" && ! -L "$manifest" ]] || die "missing local DEB manifest: $manifest"

matches=0
selected=
while IFS=$'\t' read -r source name package version architecture row_purpose; do
    [[ "$row_purpose" == "$purpose" ]] || continue
    [[ "$source" != /* && "$source" != *..* &&
       "$name" =~ ^[A-Za-z0-9._+~-]+\.deb$ &&
       "$package" =~ ^[a-z0-9][a-z0-9+.-]*$ &&
       "$version" =~ ^[A-Za-z0-9.+:~_-]+$ &&
       "$architecture" =~ ^(arm64|all)$ ]] ||
        die "invalid local DEB manifest row for purpose ${purpose}"
    candidate="${asset_dir}/debs/${name}"
    [[ -s "$candidate" && ! -L "$candidate" ]] ||
        die "missing local DEB payload: $candidate"
    actual="$(dpkg-deb -f "$candidate" Package)"$'\t'
    actual+="$(dpkg-deb -f "$candidate" Version)"$'\t'
    actual+="$(dpkg-deb -f "$candidate" Architecture)"
    [[ "$actual" == "${package}"$'\t'"${version}"$'\t'"${architecture}" ]] ||
        die "local DEB metadata changed: $candidate"
    selected="$candidate"
    (( matches += 1 ))
done <"$manifest"

(( matches == 1 )) ||
    die "purpose ${purpose} must select exactly one local DEB, found ${matches}"
printf '%s\n' "$selected"
