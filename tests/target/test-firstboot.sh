#!/usr/bin/env bash
set -Eeuo pipefail

mode="${1:-default}"
[[ "$mode" == default || "$mode" == completed ]] || {
    echo "usage: sudo tests/target/test-firstboot.sh [default|completed]" >&2
    exit 2
}
die() { echo "ERROR: $*" >&2; exit 1; }
[[ "$EUID" -eq 0 ]] || die "run as root"
[[ -x /usr/libexec/ubuntu-firstboot ]] || die "firstboot engine is missing"
[[ "$(passwd -S root | awk '{print $2}')" == L ]] || die "root account is not locked"
if [[ "$mode" == default ]]; then
    [[ -e /var/lib/ubuntu-firstboot/pending ]] || die "console firstboot is not pending"
    systemctl is-enabled --quiet ubuntu-firstboot.service || die "firstboot service is disabled"
    [[ -e /etc/ssh/sshd_config.d/00-firstboot-lockdown.conf ]] || die "SSH lockdown is missing"
    awk -F: '$3 >= 1000 && $3 < 65534 && $7 !~ /(nologin|false)$/ {exit 1}' /etc/passwd || die "image has a preset login account"
else
    [[ ! -e /var/lib/ubuntu-firstboot/pending ]] || die "firstboot is still pending"
    [[ -s /var/lib/ubuntu-firstboot/customer-user ]] || die "customer account record is missing"
    customer="$(</var/lib/ubuntu-firstboot/customer-user)"
    id "$customer" >/dev/null || die "customer account does not exist"
    groups "$customer" | grep -Eq '(^|[[:space:]])sudo([[:space:]]|$)' || die "customer is not an administrator"
fi
echo "UBUNTU_FIRSTBOOT_QA=${mode}:pass"
