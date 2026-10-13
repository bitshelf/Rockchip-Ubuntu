#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
enable=yes
profile=server

usage() {
    echo "usage: scripts/install-firstboot.sh <rootfs> [--profile server|desktop|desktop-xfce] [--enable-console|--disable-console]"
}
die() { echo "ERROR: $*" >&2; exit 1; }

(( $# >= 1 )) || { usage >&2; exit 2; }
rootfs="$1"
shift
while (( $# > 0 )); do
    case "$1" in
        --profile)
            profile="${2:-}"
            shift 2
            ;;
        --disable-console)
            enable=no
            shift
            ;;
        --enable-console)
            enable=yes
            shift
            ;;
        *) usage >&2; exit 2 ;;
    esac
done
[[ "$profile" == server || "$profile" == desktop || "$profile" == desktop-xfce ]] || die "invalid profile: $profile"
[[ "$rootfs" == /* && -d "$rootfs" && ! -L "$rootfs" ]] || die "rootfs must be an absolute directory"

source_root="${PROJECT_DIR}/package/firstboot"
while IFS= read -r -d '' directory; do
    relative="${directory#"$source_root"}"
    install -d -m 0755 "$rootfs$relative"
done < <(find "$source_root" -type d -print0 | sort -z)
while IFS= read -r -d '' source; do
    relative="${source#"$source_root"}"
    mode=0644
    [[ "$relative" == /usr/libexec/ubuntu-firstboot ]] && mode=0755
    install -m "$mode" "$source" "$rootfs$relative"
done < <(find "$source_root" -type f -print0 | sort -z)
install -d -m 0755 "$rootfs/etc/default"
# Keep login shell defaults consistent with the firstboot administrator.
# Preserve unrelated settings and service-account shells.
python3 - "$rootfs" <<'PY'
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
for relative, key in (("etc/default/useradd", "SHELL"),
                      ("etc/adduser.conf", "DSHELL")):
    path = root / relative
    content = path.read_text() if path.exists() else ""
    pattern = rf"(?m)^[ \t]*{key}[ \t]*=.*$"
    setting = f"{key}=/bin/bash"
    if re.search(pattern, content):
        content = re.sub(pattern, setting, content)
    else:
        content = content.rstrip("\n") + "\n" + setting + "\n"
    path.write_text(content)

passwd = root / "etc/passwd"
if passwd.exists():
    entries = []
    for line in passwd.read_text().splitlines():
        fields = line.split(":")
        if len(fields) == 7 and fields[0] == "root":
            fields[6] = "/bin/bash"
            line = ":".join(fields)
        entries.append(line)
    passwd.write_text("\n".join(entries) + "\n")
PY
cat >"$rootfs/etc/default/ubuntu-firstboot" <<EOF
FIRSTBOOT_PROFILE=${profile}
FIRSTBOOT_DESKTOP_AUTOLOGIN=no
EOF

# Customer delivery enables interactive account creation by default.
# Explicitly disabling it requires a separate manufacturing account policy.
rm -f "$rootfs/var/lib/ubuntu-firstboot/pending" \
    "$rootfs/etc/ssh/sshd_config.d/00-firstboot-lockdown.conf" \
    "$rootfs/etc/systemd/system/multi-user.target.wants/ubuntu-firstboot.service"
if [[ "$enable" == yes ]]; then
    install -d -m 0700 "$rootfs/var/lib/ubuntu-firstboot"
    install -d -m 0755 "$rootfs/etc/ssh/sshd_config.d"
    : >"$rootfs/var/lib/ubuntu-firstboot/pending"
    chmod 0600 "$rootfs/var/lib/ubuntu-firstboot/pending"
    install -m 0644 \
        "$rootfs/usr/share/ubuntu-firstboot/00-firstboot-lockdown.conf" \
        "$rootfs/etc/ssh/sshd_config.d/00-firstboot-lockdown.conf"
    install -d -m 0755 "$rootfs/etc/systemd/system/multi-user.target.wants"
    ln -s ../ubuntu-firstboot.service \
        "$rootfs/etc/systemd/system/multi-user.target.wants/ubuntu-firstboot.service"
fi
