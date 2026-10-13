#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
engine="$PROJECT_DIR/package/firstboot/usr/libexec/ubuntu-firstboot"
unit="$PROJECT_DIR/package/firstboot/etc/systemd/system/ubuntu-firstboot.service"
tmp_dir="$(mktemp -d)"
trap 'rm -rf -- "$tmp_dir"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

rootfs="$tmp_dir/rootfs"
install -d "$rootfs/etc/default"
printf '# user defaults\nSHELL=/bin/sh\nHOME=/home\n' >"$rootfs/etc/default/useradd"
printf '# adduser defaults\nDSHELL=/bin/sh\nDHOME=/home\n' >"$rootfs/etc/adduser.conf"
printf 'root:x:0:0:root:/root:/bin/sh\ndaemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin\n' >"$rootfs/etc/passwd"
"$PROJECT_DIR/scripts/install-firstboot.sh" "$rootfs" --profile server
grep -Fxq 'SHELL=/bin/bash' "$rootfs/etc/default/useradd" || fail "useradd default is not Bash"
grep -Fxq 'DSHELL=/bin/bash' "$rootfs/etc/adduser.conf" || fail "adduser default is not Bash"
grep -Fxq 'HOME=/home' "$rootfs/etc/default/useradd" || fail "useradd settings were discarded"
grep -Fxq 'DHOME=/home' "$rootfs/etc/adduser.conf" || fail "adduser settings were discarded"
grep -Fxq 'root:x:0:0:root:/root:/bin/bash' "$rootfs/etc/passwd" || fail "root shell is not Bash"
grep -Fxq 'daemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin' "$rootfs/etc/passwd" || fail "service shell changed"
cp "$rootfs/etc/default/useradd" "$tmp_dir/useradd.before"
"$PROJECT_DIR/scripts/install-firstboot.sh" "$rootfs" --profile server
cmp "$tmp_dir/useradd.before" "$rootfs/etc/default/useradd" || fail "shell policy is not idempotent"
[[ -x "$rootfs/usr/libexec/ubuntu-firstboot" ]] || fail "engine was not installed"
[[ -f "$rootfs/var/lib/ubuntu-firstboot/pending" ]] || fail "console firstboot is not enabled by default"
[[ -L "$rootfs/etc/systemd/system/multi-user.target.wants/ubuntu-firstboot.service" ]] || fail "firstboot unit is not enabled by default"
[[ -s "$rootfs/etc/ssh/sshd_config.d/00-firstboot-lockdown.conf" ]] || fail "SSH is not locked before account creation"
grep -Fxq 'StandardInput=null' "$unit" || fail "systemd still owns firstboot console input"
grep -Fxq 'StandardOutput=journal+console' "$unit" || fail "firstboot prompts do not reach console and journal"
! grep -Fq 'TTYVHangup=' "$unit" || fail "systemd can hang up the firstboot console"

enabled="$tmp_dir/enabled"
install -d "$enabled"
"$PROJECT_DIR/scripts/install-firstboot.sh" "$enabled" --profile desktop --enable-console
[[ -f "$enabled/var/lib/ubuntu-firstboot/pending" ]] || fail "enabled integration has no pending marker"
[[ -L "$enabled/etc/systemd/system/multi-user.target.wants/ubuntu-firstboot.service" ]] || fail "enabled integration has no unit link"
grep -Fxq 'FIRSTBOOT_PROFILE=desktop' "$enabled/etc/default/ubuntu-firstboot" || fail "Desktop profile is missing"
grep -Fxq 'SHELL=/bin/bash' "$enabled/etc/default/useradd" || fail "fresh Desktop useradd default is not Bash"
grep -Fxq 'DSHELL=/bin/bash' "$enabled/etc/adduser.conf" || fail "fresh Desktop adduser default is not Bash"

export UBUNTU_FIRSTBOOT_LIBRARY_ONLY=1
# shellcheck disable=SC1090
source "$engine"
[[ "$(UBUNTU_FIRSTBOOT_CONSOLE_ACTIVE_FILE=/dev/null true 2>/dev/null || true)" == '' ]]
valid_username ubuntuqa || fail "valid username was rejected"
! valid_username root || fail "root username was accepted"
console_active_file="$tmp_dir/console-active"
printf 'tty0 ttyFIQ0\n' >"$console_active_file"
[[ "$(console_getty_unit)" == serial-getty@ttyFIQ0.service ]] || fail "serial console getty was not identified"
printf 'tty1\n' >"$console_active_file"
[[ "$(console_getty_unit)" == getty@tty1.service ]] || fail "virtual console getty was not identified"

console_device="$tmp_dir/console"
: >"$tmp_dir/empty"
printf 'ubuntuqa\npassword-sample\n' >"$tmp_dir/input"
ln -s "$tmp_dir/empty" "$console_device"
(
    sleep 1.5
    ln -s "$tmp_dir/input" "$tmp_dir/console.new"
    mv -Tf "$tmp_dir/console.new" "$console_device"
) &
writer=$!
username=
read_username 2>"$tmp_dir/read.stderr"
IFS= read -r password_sample
wait "$writer"
[[ "$username" == ubuntuqa && "$password_sample" == password-sample ]] || fail "console reopen did not preserve FD 0 for passwd"
! grep -Eq 'passwd[[:space:]]+root|chpasswd.*root' "$engine" || fail "engine changes the root password"

echo "Ubuntu firstboot engine checks passed"

disabled="$tmp_dir/disabled"
install -d "$disabled"
"$PROJECT_DIR/scripts/install-firstboot.sh" "$disabled" --disable-console
[[ ! -e "$disabled/var/lib/ubuntu-firstboot/pending" ]] || fail "explicit disable was ignored"
seed="$PROJECT_DIR/config/ubuntu-image/resolute-server-arm64.yaml.in"
grep -Eq '^[[:space:]]*users:[[:space:]]*\[\]' "$seed" || fail "image still pre-creates users"
! grep -Eq '^[[:space:]]*(chpasswd|password|passwd|plain_text_passwd|hashed_passwd):' "$seed" || fail "image contains preset credentials"
! grep -Eq 'chage.*-d[[:space:]]*0|passwd.*--expire' "$engine" || fail "firstboot forces a second password change"

# Exercise completion and the next boot without changing host accounts/services.
(
    state_dir="$tmp_dir/state"
    install -d "$state_dir"
    pending="$state_dir/pending"
    customer_file="$state_dir/customer-user"
    lock="$state_dir/lock"
    : >"$pending"
    claim_console() { :; }
    release_console() { :; }
    read_username() { username=customer; }
    ensure_user() { printf '%s\n' "$1" >>"$state_dir/created"; }
    passwd() { printf '%s\n' "$1" >>"$state_dir/password-set"; }
    configure_desktop_autologin() { :; }
    chown() { :; }
    sync() { :; }
    systemctl() { :; }
    rm() {
        [[ "$*" == '-f /etc/ssh/sshd_config.d/00-firstboot-lockdown.conf' ]] && return 0
        command rm "$@"
    }
    (main)
    [[ ! -e "$pending" ]] || fail "completion kept pending marker"
    [[ "$(cat "$customer_file")" == customer ]] || fail "customer identity was not saved"
    (main)
    [[ "$(wc -l <"$state_dir/password-set")" == 1 ]] || fail "second boot requested another password"
    [[ "$(wc -l <"$state_dir/created")" == 1 ]] || fail "second boot created another account"
)
echo "Firstboot completion and second-boot checks passed"
