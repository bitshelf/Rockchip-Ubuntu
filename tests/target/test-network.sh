#!/usr/bin/env bash
set -Eeuo pipefail

fail() { echo "FAIL: $*" >&2; exit 1; }
for tool in ip networkctl resolvectl getent curl; do
    command -v "$tool" >/dev/null || fail "missing network tool: $tool"
done
systemctl is-active --quiet systemd-networkd || fail "networkd is inactive"
systemctl is-active --quiet systemd-resolved || fail "resolved is inactive"
route="$(ip -4 route show default)"
[[ -n "$route" ]] || fail "no IPv4 default route"
interface="$(awk 'NR == 1 {for (i=1;i<NF;i++) if ($i=="dev") {print $(i+1); exit}}' <<<"$route")"
[[ -e "/sys/class/net/$interface/device" ]] || fail "default route is not on a physical interface"
[[ "$(cat "/sys/class/net/$interface/carrier")" == 1 ]] || fail "default interface has no carrier"
networkctl status "$interface" --no-pager
ip -4 address show dev "$interface"
printf '%s\n' "$route"
resolvectl status "$interface" --no-pager
host="${NETWORK_QA_HOST:-mirrors.tuna.tsinghua.edu.cn}"
getent ahostsv4 "$host" || fail "DNS lookup failed for $host"
curl --noproxy '*' --fail --silent --show-error --head --connect-timeout 10 \
    --max-time 30 "https://$host/" >/dev/null || fail "direct HTTPS failed for $host"
printf 'NETWORK_OK interface=%s dns=%s https=direct\n' "$interface" "$host"
