#!/usr/bin/env bash
set -Eeuo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }

[[ "$(id -u)" -eq 0 ]] || die "ADB/serial QA must run as root"
command -v ip >/dev/null || die "ip is unavailable"
temporary="$(mktemp)" || die "ADB shell temporary directory is unusable"
rm -f "$temporary"
systemctl is-active --quiet adbd-gadget.service ||
    die "adbd-gadget.service is not active"
systemctl is-active --quiet adbd.service || die "adbd.service is not active"
mountpoint -q /dev/usb-ffs/adb || die "ADB FunctionFS is not mounted"

main_pid="$(systemctl show -p MainPID --value adbd.service)"
[[ "$main_pid" =~ ^[1-9][0-9]*$ ]] || die "adbd has no live MainPID"
host_namespace="$(readlink /proc/1/ns/net)"
adbd_namespace="$(readlink "/proc/${main_pid}/ns/net")"
[[ "$adbd_namespace" == "$host_namespace" ]] ||
    die "adbd uses a different network namespace"

gadget=
for path in /sys/kernel/config/usb_gadget/*; do
    [[ -d "$path/functions/ffs.adb" ]] || continue
    gadget="$path"
    break
done
[[ -n "$gadget" && -s "$gadget/UDC" ]] || die "ADB gadget is not bound"

# `ip -o -c address` retains the explicitly requested ANSI color while
# normalizing changing address lifetimes. Run this script once through serial and
# once through ADB; matching hashes prove both transports see the same stable
# interface/address view.
network_snapshot="$(ip -o -c address show |
    sed -E 's/valid_lft [^ ]+ preferred_lft [^ ]+/valid_lft <lease> preferred_lft <lease>/')"
[[ -n "$network_snapshot" ]] || die "ip returned no interfaces"
network_sha256="$(printf '%s\n' "$network_snapshot" | sha256sum | awk '{print $1}')"
interface_count="$(ip -o link show | wc -l)"

printf '{"schema":"ubuntu-adb-qa-v1","result":"pass",'
printf '"uid":0,"network_namespace":"%s",' "$host_namespace"
printf '"interface_count":%s,"ip_color_sha256":"%s"}\n' \
    "$interface_count" "$network_sha256"
