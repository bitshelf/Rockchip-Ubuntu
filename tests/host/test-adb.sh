#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
service="$PROJECT_DIR/package/adb/etc/systemd/system/adbd.service"
gadget="$PROJECT_DIR/package/adb/usr/libexec/rk-adbd-gadget"
tmp_dir="$(mktemp -d)"
trap 'rm -rf -- "$tmp_dir"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

rootfs="$tmp_dir/rootfs"
install -D -m 0755 /bin/true \
    "$rootfs/usr/lib/android-sdk/platform-tools/adbd"
"$PROJECT_DIR/scripts/install-adb.sh" "$rootfs"

[[ -x "$rootfs/usr/libexec/rk-adbd-gadget" ]] ||
    fail "ADB gadget helper was not installed"
[[ -L "$rootfs/etc/systemd/system/sysinit.target.wants/adbd.service" ]] ||
    fail "ADB service was not enabled"
[[ "$(readlink "$rootfs/etc/systemd/system/sysinit.target.wants/adbd.service")" == ../adbd.service ]] ||
    fail "ADB service link has an unexpected target"
grep -Fq 'ExecStart=/usr/lib/android-sdk/platform-tools/adbd' "$service" ||
    fail "service does not run the Ubuntu adbd binary"
grep -Fq 'Requires=adbd-gadget.service' "$service" ||
    fail "service does not order the USB gadget"

for restriction in PrivateNetwork NetworkNamespacePath User DynamicUser \
        NoNewPrivileges CapabilityBoundingSet AmbientCapabilities \
        RestrictAddressFamilies SystemCallFilter; do
    ! grep -Eq "^[[:space:]]*${restriction}=" "$service" ||
        fail "unnecessary adbd restriction is present: ${restriction}"
done
grep -Fq 'for path in /sys/class/udc/*' "$gadget" ||
    fail "USB gadget does not discover UDCs dynamically"
! grep -Eq '/sys/class/udc/[0-9a-f]+\.' "$gadget" ||
    fail "USB gadget contains a board-specific UDC path"

echo "ADB root shell and host-network policy checks passed"
