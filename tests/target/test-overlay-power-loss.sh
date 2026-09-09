#!/usr/bin/env bash
set -Eeuo pipefail

state_dir=/var/lib/ubuntu-qa/overlay-power-loss
backing_dir=/var/lib/overlay-root
mode="${1:-}"

die() { echo "ERROR: $*" >&2; exit 1; }
[[ "$EUID" -eq 0 ]] || die "run as root"

root_is_overlay() {
    [[ "$(findmnt -n -o FSTYPE / 2>/dev/null || true)" == overlay ]]
}

mount_has_option() {
    local target="$1" expected="$2" options
    options="$(findmnt -n -o OPTIONS "$target" 2>/dev/null || true)"
    [[ ",$options," == *",$expected,"* ]]
}

backing_has_userdata_partlabel() {
    local source
    source="$(findmnt -n -o SOURCE "$backing_dir" 2>/dev/null || true)"
    [[ -n "$source" &&
       "$(blkid -s PARTLABEL -o value "$source" 2>/dev/null || true)" == userdata ]]
}

case "$mode" in
    prepare)
        root_is_overlay || die "root filesystem is not OverlayFS"
        [[ "$(findmnt -n -o FSTYPE /.rootfs-ro 2>/dev/null || true)" == erofs ]] ||
            die "immutable lower root is not EROFS"
        mount_has_option /.rootfs-ro ro || die "immutable lower root is not read-only"
        [[ "$(findmnt -n -o FSTYPE "$backing_dir" 2>/dev/null || true)" == ext4 ]] ||
            die "overlay backing store is not ext4"
        mount_has_option "$backing_dir" rw || die "overlay backing store is not writable"
        backing_has_userdata_partlabel || die "overlay backing store is not PARTLABEL=userdata"
        install -d -m 0700 "$state_dir"
        token="$(date -u +%Y%m%dT%H%M%SZ)-$$"
        printf '%s\n' "$token" >"$state_dir/baseline"
        sync "$state_dir/baseline"
        printf '%s\n' "$token" >"$state_dir/armed"
        sync "$state_dir/armed"
        echo "POWER_LOSS_ARMED=$token"
        echo "Next: sudo $0 write-loop, then cut board power while it is running."
        ;;
    write-loop)
        [[ -s "$state_dir/armed" ]] || die "run prepare first"
        sequence=0
        while :; do
            slot=$((sequence % 32))
            temporary="$state_dir/.record-${slot}.tmp"
            completed="$state_dir/record-${slot}"
            {
                printf 'BEGIN %s\n' "$sequence"
                dd if=/dev/zero bs=1M count=4 status=none
                printf '\nEND %s\n' "$sequence"
            } >"$temporary"
            mv -f -- "$temporary" "$completed"
            printf '%s\n' "$sequence" >"$state_dir/last-sequence"
            sequence=$((sequence + 1))
        done
        ;;
    verify)
        root_is_overlay || die "root filesystem is not OverlayFS after power cut"
        [[ "$(findmnt -n -o FSTYPE /.rootfs-ro 2>/dev/null || true)" == erofs ]] ||
            die "EROFS lower is missing after power cut"
        mount_has_option /.rootfs-ro ro || die "EROFS lower is writable after power cut"
        [[ "$(findmnt -n -o FSTYPE "$backing_dir" 2>/dev/null || true)" == ext4 ]] ||
            die "ext4 backing store is missing after power cut"
        mount_has_option "$backing_dir" rw || die "ext4 backing store is read-only after recovery"
        backing_has_userdata_partlabel || die "recovered backing store is not PARTLABEL=userdata"
        [[ -s "$state_dir/baseline" && -s "$state_dir/armed" ]] ||
            die "persistent baseline was lost"
        expected="$(<"$state_dir/armed")"
        [[ "$(<"$state_dir/baseline")" == "$expected" ]] ||
            die "persistent baseline changed"
        upper_baseline="${backing_dir}/upper${state_dir}/baseline"
        [[ -s "$upper_baseline" ]] || die "baseline is absent from OverlayFS upper"
        [[ ! -e "/.rootfs-ro${state_dir}/baseline" ]] ||
            die "power-loss probe modified the immutable lower"
        bad_records=0
        record_count=0
        while IFS= read -r -d '' record; do
            record_count=$((record_count + 1))
            first="$(head -n1 "$record")"
            last="$(tail -n1 "$record")"
            [[ "$first" =~ ^BEGIN[[:space:]]+([0-9]+)$ &&
               "$last" == "END ${BASH_REMATCH[1]}" ]] || bad_records=$((bad_records + 1))
        done < <(find "$state_dir" -maxdepth 1 -type f -name 'record-*' -print0)
        (( record_count > 0 )) || die "no completed record survived the power cut"
        (( bad_records == 0 )) || die "found $bad_records torn completed records"
        if dmesg | grep -Eiq 'EXT4-fs (error|warning)|overlayfs:.*(error|failed)|Buffer I/O error'; then
            die "kernel log contains filesystem recovery errors"
        fi
        echo "POWER_LOSS_OVERLAY_OK=$expected"
        ;;
    *)
        echo "usage: sudo $0 <prepare|write-loop|verify>" >&2
        exit 2
        ;;
esac
