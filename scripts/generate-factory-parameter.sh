#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
die() { echo "ERROR: $*" >&2; exit 1; }

[[ $# -eq 3 ]] ||
    die "usage: $0 <rootfs.erofs.img> <bootfs.img> <output-parameter.txt>"
rootfs="$1"
bootfs="$2"
output="$3"
reference="${FACTORY_PARAMETER_FILE:-${PROJECT_DIR}/config/factory/parameter.txt}"
round_mb="${ROOTFS_ROUND_MB:-128}"

for input in "$reference" "$rootfs" "$bootfs"; do
    [[ -s "$input" && ! -L "$input" ]] || die "missing parameter input: $input"
done
[[ "$output" == /* && "$output" != *[[:space:]]* ]] ||
    die "parameter output must be an absolute path without whitespace"
[[ "$output" != "$reference" ]] || die "output must not overwrite the reference parameter"
[[ "$round_mb" =~ ^[1-9][0-9]*$ ]] || die "ROOTFS_ROUND_MB must be a positive integer"

rootfs_bytes="$(stat -c %s "$rootfs")"
bootfs_bytes="$(stat -c %s "$bootfs")"
(( rootfs_bytes > 0 && rootfs_bytes % 512 == 0 )) ||
    die "rootfs image must be a positive multiple of 512 bytes"
(( bootfs_bytes > 0 && bootfs_bytes % 512 == 0 )) ||
    die "bootfs image must be a positive multiple of 512 bytes"

round_bytes=$(( round_mb * 1024 * 1024 ))
rootfs_capacity_bytes=$(( (rootfs_bytes + round_bytes - 1) / round_bytes * round_bytes ))
rootfs_capacity_sectors=$(( rootfs_capacity_bytes / 512 ))
bootfs_sectors=$(( bootfs_bytes / 512 ))

cmdline="$(grep -m1 '^CMDLINE: mtdparts=:' "$reference" || true)"
[[ -n "$cmdline" ]] || die "reference parameter has no Rockchip mtdparts CMDLINE"
IFS=',' read -r -a partitions <<<"${cmdline#CMDLINE: mtdparts=:}"

rewritten=()
cursor=
found_boot=0
found_rootfs=0
fixed_re='^0x([0-9a-fA-F]+)@0x([0-9a-fA-F]+)\(([^)]+)\)$'
grow_re='^-@0x([0-9a-fA-F]+)\(([^)]+)\)$'
for partition in "${partitions[@]}"; do
    if [[ "$partition" =~ $fixed_re ]]; then
        size=$(( 16#${BASH_REMATCH[1]} ))
        offset=$(( 16#${BASH_REMATCH[2]} ))
        name="${BASH_REMATCH[3]}"
        [[ "$name" != bootfs ]] || die "reference must not contain a second bootfs partition"
        case "$name" in
            boot)
                (( found_boot == 0 )) || die "duplicate boot partition"
                found_boot=1
                size="$bootfs_sectors"
                cursor="$offset"
                ;;
            rootfs)
                (( found_boot == 1 && found_rootfs == 0 )) ||
                    die "rootfs must follow exactly one boot partition"
                found_rootfs=1
                size="$rootfs_capacity_sectors"
                ;;
        esac
        if [[ -z "$cursor" ]]; then
            rewritten+=("$partition")
        else
            printf -v entry '0x%08x@0x%08x(%s)' "$size" "$cursor" "$name"
            rewritten+=("$entry")
            cursor=$(( cursor + size ))
        fi
    elif [[ "$partition" =~ $grow_re ]]; then
        (( found_rootfs == 1 )) || die "grow partition must follow rootfs"
        printf -v entry -- '-@0x%08x(%s)' "$cursor" "${BASH_REMATCH[2]}"
        rewritten+=("$entry")
    else
        die "cannot parse reference partition: $partition"
    fi
done
(( found_boot == 1 && found_rootfs == 1 )) ||
    die "reference must contain fixed boot and rootfs partitions"

new_parts="$(IFS=,; echo "${rewritten[*]}")"
install -d -m 2775 "$(dirname "$output")"
stage="${output}.stage.$$"
trap 'rm -f -- "$stage"' EXIT
sed "s|^CMDLINE: mtdparts=:.*$|CMDLINE: mtdparts=:${new_parts}|" \
    "$reference" >"$stage"
chmod 0644 "$stage"
mv -f -- "$stage" "$output"
trap - EXIT

printf 'rootfs-capacity=%s sectors (%s MiB), rootfs-payload=%s bytes\n' \
    "$rootfs_capacity_sectors" "$(( rootfs_capacity_bytes / 1024 / 1024 ))" \
    "$rootfs_bytes"
printf 'parameter=%s\n' "$output"
