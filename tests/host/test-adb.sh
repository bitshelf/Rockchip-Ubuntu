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
grep -Fq 'udc_class=/sys/class/udc' "$gadget" ||
    fail "USB gadget does not discover UDCs dynamically"
! grep -Eq '/sys/class/udc/[0-9a-f]+\.' "$gadget" ||
    fail "USB gadget contains a board-specific UDC path"

# Exercise the controller lifecycle against sysfs-like files: repeated binds
# must retain the original policy, and reset must issue a real ConfigFS write.
GADGET_LIBRARY="$gadget" FIXTURE="$tmp_dir/controller" sh <<'SH'
set -eu
RK_ADBD_GADGET_LIBRARY_ONLY=1
. "$GADGET_LIBRARY"
gadget="$FIXTURE/gadget"
udc_class="$FIXTURE/udc"
power_state="$FIXTURE/state"
mkdir -p "$gadget" "$udc_class/mock/device/power"
printf 'auto\n' >"$udc_class/mock/device/power/control"
hold_controller mock
hold_controller mock
[ "$(cat "$power_state/mock")" = auto ]
[ "$(cat "$udc_class/mock/device/power/control")" = on ]
printf 'mock\n' >"$gadget/UDC"
unbind
[ "$(wc -c <"$gadget/UDC")" -eq 1 ]
[ "$(cat "$udc_class/mock/device/power/control")" = auto ]
[ ! -e "$power_state/mock" ]
# Controllers with no runtime-PM interface remain supported.
hold_controller no-power-control
release_controller no-power-control
SH

echo "ADB root shell and host-network policy checks passed"
