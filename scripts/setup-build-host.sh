#!/usr/bin/env bash
set -Eeuo pipefail

MODE=setup
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

usage() {
    cat <<'EOF'
usage: setup-build-host.sh [--check|--self-test]

Install Forgejo and the Ubuntu rootfs build environment on a Debian or Ubuntu
host. Native ARM64 is preferred; x86_64 installs the ARM64 QEMU prerequisites.

The script is self-contained and may be copied to a host and run directly.

Environment:
  CI_USER                dedicated host runner account (default: ubuntu-ci)
  FORGEJO_PUBLIC_HOST    IP address or DNS name advertised by Forgejo
  FORGEJO_VERSION        Forgejo container major version (default: 15)
  RUNNER_VERSION         Forgejo runner version (default: 12.7.3)
  FORGEJO_ADMIN_USER     initial administrator (default: ubuntu)
  FORGEJO_ADMIN_EMAIL    initial administrator email
  BUILD_OUTPUT_DIR       shared native/CI build output directory
  BUILD_STORAGE_ROOT     backing filesystem for standard /var/lib container data
  APT_MIRROR             explicit Debian/Ubuntu mirror (default: domestic auto)
  SNAP_REFRESH_HOLD      snap refresh duration for the workaround (default: forever)
  APT_PROXY              local apt-cacher-ng URL
  HTTP_PROXY             optional upstream HTTP proxy
  HTTPS_PROXY            optional upstream HTTPS proxy
  NO_PROXY               proxy exclusions
EOF
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

host_arch() {
    case "$(uname -m)" in
        aarch64|arm64) echo arm64 ;;
        x86_64|amd64) echo amd64 ;;
        *) die "unsupported host architecture: $(uname -m)" ;;
    esac
}

compose_yaml() {
    cat <<EOF
services:
  forgejo:
    image: data.forgejo.org/forgejo/forgejo:${FORGEJO_VERSION}
    container_name: forgejo
    restart: unless-stopped
    environment:
      USER_UID: "1000"
      USER_GID: "1000"
      FORGEJO__database__DB_TYPE: sqlite3
      FORGEJO__server__DOMAIN: ${FORGEJO_PUBLIC_HOST}
      FORGEJO__server__ROOT_URL: http://${FORGEJO_PUBLIC_HOST}:3000/
      FORGEJO__server__SSH_DOMAIN: ${FORGEJO_PUBLIC_HOST}
      FORGEJO__server__SSH_PORT: "2222"
      FORGEJO__service__DISABLE_REGISTRATION: "true"
      FORGEJO__security__INSTALL_LOCK: "true"
      FORGEJO__actions__ENABLED: "true"
      FORGEJO__actions__DEFAULT_ACTIONS_URL: https://data.forgejo.org
      FORGEJO__actions__ARTIFACT_RETENTION_DAYS: "30"
    volumes:
      - ${FORGEJO_DATA_DIR}:/data
      - /etc/localtime:/etc/localtime:ro
    ports:
      - "3000:3000"
      - "2222:22"
EOF
}

runner_config() {
    cat <<EOF
log:
  level: info

runner:
  file: ${RUNNER_DIR}/.runner
  capacity: 1
  timeout: 12h
  fetch_timeout: 30s
  fetch_interval: 5s
  labels:
    - ${RUNNER_LABEL}

cache:
  enabled: true
  dir: ${CI_HOME}/.cache/forgejo-runner
EOF
}

self_test() {
    local output

    output="$(compose_yaml)"
    grep -Fq "forgejo/forgejo:${FORGEJO_VERSION}" <<<"$output"
    grep -Fq '2222:22' <<<"$output"
    output="$(runner_config)"
    grep -Fq 'capacity: 1' <<<"$output"
    grep -Fq "$RUNNER_LABEL" <<<"$output"
    host_arch >/dev/null
    echo "Build-host script self-test passed"
}

case "${1:-}" in
    "") ;;
    --check) MODE=check ;;
    --self-test) MODE=self-test ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
esac
(( $# <= 1 )) || { usage >&2; exit 2; }

if [[ -f "${PROJECT_DIR}/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "${PROJECT_DIR}/.env"
    set +a
fi

CI_USER="${CI_USER:-ubuntu-ci}"
FORGEJO_VERSION="${FORGEJO_VERSION:-15}"
RUNNER_VERSION="${RUNNER_VERSION:-12.7.3}"
FORGEJO_PUBLIC_HOST="${FORGEJO_PUBLIC_HOST:-$(hostname -I 2>/dev/null | awk '{print $1}')}"
FORGEJO_PUBLIC_HOST="${FORGEJO_PUBLIC_HOST:-127.0.0.1}"
FORGEJO_ADMIN_USER="${FORGEJO_ADMIN_USER:-ubuntu}"
FORGEJO_ADMIN_EMAIL="${FORGEJO_ADMIN_EMAIL:-ubuntu@localhost}"
FORGEJO_DATA_DIR="${FORGEJO_DATA_DIR:-/var/lib/forgejo}"
UBUNTU_CI_CONFIG_DIR="${UBUNTU_CI_CONFIG_DIR:-/etc/ubuntu-ci}"
FORGEJO_COMPOSE="${UBUNTU_CI_CONFIG_DIR}/forgejo-compose.yaml"
CI_HOME="${CI_HOME:-/home/${CI_USER}}"
RUNNER_DIR="${CI_HOME}/.config/forgejo-runner"
if [[ "$(host_arch)" == arm64 ]]; then
    RUNNER_LABEL=native-arm64:host
    BUILD_OUTPUT_DIR="${BUILD_OUTPUT_DIR:-/var/lib/ubuntu-ci/build}"
else
    RUNNER_LABEL=ubuntu-image-amd64:host
    BUILD_OUTPUT_DIR="${BUILD_OUTPUT_DIR:-${PROJECT_DIR}/build}"
fi
[[ "$BUILD_OUTPUT_DIR" == /* ]] ||
    die "BUILD_OUTPUT_DIR must be an absolute path: $BUILD_OUTPUT_DIR"

if [[ "$MODE" == self-test ]]; then
    self_test
    exit 0
fi

HTTP_PROXY="${HTTP_PROXY:-${http_proxy:-}}"
HTTPS_PROXY="${HTTPS_PROXY:-${https_proxy:-$HTTP_PROXY}}"
NO_PROXY="${NO_PROXY:-${no_proxy:-127.0.0.1,localhost,::1}}"
APT_PROXY="${APT_PROXY:-http://127.0.0.1:3142}"
export HTTP_PROXY HTTPS_PROXY NO_PROXY
export http_proxy="${http_proxy:-$HTTP_PROXY}"
export https_proxy="${https_proxy:-$HTTPS_PROXY}"
export no_proxy="${no_proxy:-$NO_PROXY}"

if [[ "$MODE" == setup && "$EUID" -ne 0 ]]; then
    exec sudo --preserve-env=CI_USER,FORGEJO_VERSION,RUNNER_VERSION,FORGEJO_PUBLIC_HOST,FORGEJO_ADMIN_USER,FORGEJO_ADMIN_EMAIL,BUILD_OUTPUT_DIR,BUILD_STORAGE_ROOT,APT_MIRROR,SNAP_REFRESH_HOLD,APT_PROXY,HTTP_PROXY,HTTPS_PROXY,NO_PROXY,http_proxy,https_proxy,no_proxy \
        "$0" "$@"
fi

[[ "$(systemd-detect-virt --container 2>/dev/null || true)" == none ]] ||
    die "rootfs builds must run on a non-containerized host"
[[ -e /dev/loop-control ]] || die "/dev/loop-control is required"

configure_domestic_apt_mirror() {
    local base codename distribution mirror_file mirror_path
    local -a candidates source_files

    # Do not disturb an already configured, reachable domestic mirror.
    codename="$(sed -n 's/^VERSION_CODENAME=//p' /etc/os-release)"
    distribution="$(sed -n 's/^ID=//p' /etc/os-release)"
    codename="${codename#\"}"
    codename="${codename%\"}"
    distribution="${distribution#\"}"
    distribution="${distribution%\"}"
    case "$distribution" in
        ubuntu)
            if [[ "$(host_arch)" == arm64 ]]; then
                mirror_path=ubuntu-ports
            else
                mirror_path=ubuntu
            fi
            candidates=(
                "https://mirrors.tuna.tsinghua.edu.cn/${mirror_path}"
                "https://mirrors.aliyun.com/${mirror_path}"
                "https://mirrors.cloud.tencent.com/${mirror_path}"
            )
            ;;
        debian)
            candidates=(
                https://mirrors.tuna.tsinghua.edu.cn/debian
                https://mirrors.aliyun.com/debian
                https://mirrors.cloud.tencent.com/debian
            )
            ;;
        *) die "unsupported build-host distribution: $distribution" ;;
    esac
    [[ -z "${APT_MIRROR:-}" ]] || candidates=("${APT_MIRROR%/}")
    mapfile -t source_files < <(
        find /etc/apt -maxdepth 2 -type f \( -name '*.list' -o -name '*.sources' \)
    )
    for base in "${candidates[@]}"; do
        if grep -Fqs "$base" "${source_files[@]}" 2>/dev/null &&
            curl --noproxy '*' --fail --silent --location \
                --connect-timeout 5 --max-time 15 \
                "$base/dists/$codename/InRelease" -o /dev/null; then
            echo "Using existing domestic APT mirror: $base"
            return
        fi
    done
    for base in "${candidates[@]}"; do
        if curl --noproxy '*' --fail --silent --location \
            --connect-timeout 5 --max-time 15 \
            "$base/dists/$codename/InRelease" -o /dev/null; then
            break
        fi
        base=
    done
    [[ -n "$base" ]] || die "no configured domestic APT mirror is reachable"

    for mirror_file in "${source_files[@]}"; do
        if [[ "$distribution" == ubuntu ]]; then
            sed -Ei \
                "s#https?://[^ /]+/(ubuntu-ports|ubuntu)(/)?#${base}/#g" \
                "$mirror_file"
        else
            sed -Ei \
                -e "s#https?://[^ /]+/debian-security(/)?#${base}-security/#g" \
                -e \
                "s#https?://[^ /]+/debian(/)?#${base}/#g" \
                "$mirror_file"
        fi
    done
    echo "Selected domestic APT mirror: $base"
}

enable_source_repositories() {
    local source_file generated=/etc/apt/sources.list.d/ubuntu-ci-source.list
    local temporary

    while IFS= read -r source_file; do
        sed -Ei 's/^Types:[[:space:]]*deb[[:space:]]*$/Types: deb deb-src/' \
            "$source_file"
    done < <(find /etc/apt -maxdepth 2 -type f -name '*.sources' | sort)
    temporary="$(mktemp)"
    while IFS= read -r source_file; do
        awk '$1 == "deb" { sub(/^deb[[:space:]]+/, "deb-src "); print }' \
            "$source_file"
    done < <(find /etc/apt -maxdepth 2 -type f -name '*.list' \
        ! -path "$generated" | sort) | sort -u >"$temporary"
    if [[ -s "$temporary" ]]; then
        install -m 0644 "$temporary" "$generated"
    else
        rm -f -- "$generated"
    fi
    rm -f -- "$temporary"
}

install_host_packages() {
    local packages

    [[ -d /tmp && ! -L /tmp ]] || die "/tmp must be a real directory"
    chmod 1777 /tmp
    export DEBIAN_FRONTEND=noninteractive
    export TMPDIR=/tmp
    apt-get update
    apt-get install -y --no-install-recommends ca-certificates curl
    configure_domestic_apt_mirror
    enable_source_repositories
    packages=(
        apparmor apt-cacher-ng snapd distro-info-data ubuntu-keyring
        e2fsprogs erofs-utils initramfs-tools device-tree-compiler gdisk dosfstools
        rsync git curl wget ca-certificates gnupg jq xz-utils zstd openssl
        devscripts dpkg-dev fakeroot file gzip kmod make gcc g++ libc6-dev \
        libbz2-dev quilt patch nodejs python3 sudo util-linux
        docker.io libcap2-bin
    )
    if [[ "$(host_arch)" == amd64 ]]; then
        packages+=(qemu-user-static binfmt-support)
    fi

    apt-get update
    apt-get install -y --no-install-recommends "${packages[@]}"
    if ! docker compose version >/dev/null 2>&1; then
        if apt-cache show docker-compose-v2 >/dev/null 2>&1; then
            apt-get install -y --no-install-recommends docker-compose-v2
        elif ! command -v docker-compose >/dev/null 2>&1; then
            apt-get install -y --no-install-recommends docker-compose
        fi
    fi
}

ensure_ci_account() {
    id "$CI_USER" >/dev/null 2>&1 ||
        useradd --create-home --home-dir "$CI_HOME" --shell /bin/bash "$CI_USER"
}

configure_docker_storage() {
    local configured_docker_root configured_containerd_root
    local docker_source containerd_source storage_root

    if [[ "$(findmnt -n -o FSTYPE /)" != overlay ]]; then
        return
    fi
    [[ -n "${BUILD_STORAGE_ROOT:-}" ]] ||
        die "BUILD_STORAGE_ROOT must name a real filesystem when / is OverlayFS"
    [[ -d "$BUILD_STORAGE_ROOT" ]] ||
        die "BUILD_STORAGE_ROOT does not exist: $BUILD_STORAGE_ROOT"
    [[ "$(findmnt -T "$BUILD_STORAGE_ROOT" -n -o FSTYPE)" != overlay ]] ||
        die "BUILD_STORAGE_ROOT must not be on OverlayFS"

    storage_root="${BUILD_STORAGE_ROOT%/}/ubuntu-ci/container-storage"
    docker_source="${storage_root}/docker"
    containerd_source="${storage_root}/containerd"
    configured_docker_root="$(jq -r '."data-root" // empty' \
        /etc/docker/daemon.json 2>/dev/null || true)"
    configured_docker_root="${configured_docker_root:-/var/lib/docker}"
    configured_containerd_root="$(sed -n \
        's|.*--root[ =]\([^ ]*\).*|\1|p' \
        /etc/systemd/system/containerd.service.d/*.conf 2>/dev/null |
        tail -n1 || true)"
    configured_containerd_root="${configured_containerd_root:-/var/lib/containerd}"
    systemctl stop docker.service docker.socket containerd.service 2>/dev/null || true
    install -d -m 0711 "$docker_source" "$containerd_source" \
        /var/lib/docker /var/lib/containerd
    if [[ ! -e "$docker_source/.ubuntu-build-host-migrated" ]]; then
        rsync -aHAX --numeric-ids "${configured_docker_root%/}/" "$docker_source/"
        touch "$docker_source/.ubuntu-build-host-migrated"
    fi
    if [[ ! -e "$containerd_source/.ubuntu-build-host-migrated" ]]; then
        rsync -aHAX --numeric-ids "${configured_containerd_root%/}/" \
            "$containerd_source/"
        touch "$containerd_source/.ubuntu-build-host-migrated"
    fi

    install -d -m 0755 /etc/docker /etc/systemd/system/containerd.service.d
    jq '. + {"data-root": "/var/lib/docker"}' \
        /etc/docker/daemon.json 2>/dev/null > /etc/docker/daemon.json.new ||
        jq -n '{"data-root": "/var/lib/docker"}' > /etc/docker/daemon.json.new
    mv /etc/docker/daemon.json.new /etc/docker/daemon.json
    rm -f /etc/systemd/system/containerd.service.d/10-ubuntu-build-storage.conf
    cat >/etc/systemd/system/containerd.service.d/90-ubuntu-build-standard-path.conf <<'EOF'
[Service]
ExecStart=
ExecStart=/usr/bin/containerd
EOF
    cat >/etc/systemd/system/var-lib-docker.mount <<EOF
[Unit]
Description=Docker data on build storage
RequiresMountsFor=${docker_source}
Before=docker.service

[Mount]
What=${docker_source}
Where=/var/lib/docker
Type=none
Options=bind

[Install]
WantedBy=multi-user.target
EOF
    cat >/etc/systemd/system/var-lib-containerd.mount <<EOF
[Unit]
Description=containerd data on build storage
RequiresMountsFor=${containerd_source}
Before=containerd.service

[Mount]
What=${containerd_source}
Where=/var/lib/containerd
Type=none
Options=bind

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now var-lib-docker.mount var-lib-containerd.mount
}

configure_docker_proxy() {
    local proxy_dropin

    proxy_dropin=/etc/systemd/system/docker.service.d/20-ubuntu-build-proxy.conf
    install -d -m 0755 /etc/systemd/system/docker.service.d
    if [[ -n "$HTTP_PROXY$HTTPS_PROXY" ]]; then
        cat >"$proxy_dropin" <<EOF
[Service]
Environment="HTTP_PROXY=${HTTP_PROXY}"
Environment="HTTPS_PROXY=${HTTPS_PROXY}"
Environment="NO_PROXY=${NO_PROXY}"
EOF
        chmod 0644 "$proxy_dropin"
    else
        rm -f "$proxy_dropin"
    fi
    systemctl daemon-reload
}

configure_apt_cache() {
    install -d -m 0755 /etc/apt-cacher-ng/acng.conf.d
    cat >/etc/apt-cacher-ng/acng.conf.d/ubuntu-images.conf <<'EOF'
CacheDir: /var/cache/apt-cacher-ng
LogDir: /var/log/apt-cacher-ng
Port: 3142
BindAddress: 127.0.0.1
ExTreshold: 60
DlMaxRetries: 20
NetworkTimeout: 60
DisconnectTimeout: 60
PassThroughPattern: ^(.*):443$
EOF
    if [[ -n "$HTTP_PROXY" ]]; then
        printf 'Proxy: %s\n' "$HTTP_PROXY" \
            >/etc/apt-cacher-ng/acng.conf.d/upstream-proxy.conf
        chmod 0600 /etc/apt-cacher-ng/acng.conf.d/upstream-proxy.conf
    else
        rm -f /etc/apt-cacher-ng/acng.conf.d/upstream-proxy.conf
    fi
    cat >/etc/apt/apt.conf.d/01ubuntu-build-cache <<EOF
Acquire::http::Proxy "${APT_PROXY}";
Acquire::https::Proxy "DIRECT";
EOF
    systemctl enable --now apt-cacher-ng.service
}

install_ubuntu_image() {
    systemctl enable --now apparmor.service
    systemctl enable --now snapd.socket
    snap wait system seed.loaded
    if [[ -n "$HTTP_PROXY" ]]; then
        snap set system proxy.http="$HTTP_PROXY"
    else
        snap unset system proxy.http 2>/dev/null || true
    fi
    if [[ -n "$HTTPS_PROXY" ]]; then
        snap set system proxy.https="$HTTPS_PROXY"
    else
        snap unset system proxy.https 2>/dev/null || true
    fi
    snap list ubuntu-image >/dev/null 2>&1 || snap install ubuntu-image --classic
}

repair_snap_confine_caps() {
    local conf_deb conf_snap conf_source caps_fallback helper
    local current_source target

    conf_deb=/usr/lib/snapd/snap-confine
    conf_snap=/snap/snapd/current/usr/lib/snapd/snap-confine
    conf_source=/var/lib/ubuntu-ci/snap-confine
    if runuser -u "$CI_USER" -- env HOME="$CI_HOME" \
        /snap/bin/ubuntu-image --version >/dev/null 2>&1; then
        if systemctl cat snap-confine-caps.service 2>/dev/null |
            grep -Fq "ConditionPathExists=${conf_source}"; then
            return
        fi
        current_source="$(findmnt -n -o SOURCE "$conf_snap" 2>/dev/null || true)"
        if [[ "$current_source" != */snap-confine ]]; then
            return
        fi
    fi
    caps_fallback='cap_chown,cap_dac_override,cap_dac_read_search,cap_fowner,cap_setgid,cap_setuid,cap_sys_chroot,cap_sys_ptrace,cap_sys_admin,cap_sys_resource=p'
    [[ -f "$conf_deb" ]] || die "snap-confine is unavailable: $conf_deb"
    [[ -f "$conf_snap" ]] || die "the snapd snap is not mounted: $conf_snap"

    if [[ ! -e "$conf_source" || ! "$conf_source" -ef "$conf_deb" ]]; then
        install -D -m 0755 "$conf_deb" "$conf_source"
    fi
    if [[ -s /usr/lib/snapd/snap-confine.caps ]]; then
        setcap -q - "$conf_source" </usr/lib/snapd/snap-confine.caps
    else
        setcap -q "$caps_fallback" "$conf_source"
    fi
    getcap "$conf_source" | grep -q cap_ ||
        die "cannot store snap-confine capabilities on $conf_source"

    for target in "$conf_deb" "$conf_snap"; do
        [[ "$target" == "$conf_source" ]] && continue
        if [[ ! "$target" -ef "$conf_source" ]]; then
            mount --bind "$conf_source" "$target"
        fi
        getcap "$target" | grep -q cap_ ||
            die "snap-confine capabilities are unavailable through $target"
    done

    helper=/usr/libexec/ubuntu-ci/snap-confine-caps-apply
    install -d -m 0755 /usr/libexec/ubuntu-ci
    cat >"$helper" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
source_file=${conf_source}
for target in ${conf_deb} ${conf_snap}; do
    for _ in \$(seq 1 150); do
        [[ -f "\$target" ]] && break
        sleep 2
    done
    [[ -f "\$target" ]] || exit 1
    [[ "\$target" == "\$source_file" ]] && continue
    if [[ ! "\$target" -ef "\$source_file" ]]; then
        mount --bind "\$source_file" "\$target"
    fi
done
getcap ${conf_snap} | grep -q cap_
EOF
    chmod 0755 "$helper"
    cat >/etc/systemd/system/snap-confine-caps.service <<EOF
[Unit]
Description=Restore snap-confine capabilities for Ubuntu image builds
After=local-fs.target snapd.seeded.service
Wants=snapd.seeded.service
ConditionPathExists=${conf_source}

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${helper}

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now snap-confine-caps.service
    snap refresh --hold="${SNAP_REFRESH_HOLD:-forever}"
    runuser -u "$CI_USER" -- env HOME="$CI_HOME" \
        /snap/bin/ubuntu-image --version >/dev/null ||
        die "ubuntu-image still fails after restoring snap-confine capabilities"
}

install_forgejo() {
    local compose=(docker compose)
    local credential_file password repo_status token runner_url tmp_dir
    local gpg_fingerprint
    local ci_group

    if ! docker compose version >/dev/null 2>&1; then
        compose=(docker-compose)
    fi
    id "$CI_USER" >/dev/null 2>&1 ||
        useradd --create-home --home-dir "$CI_HOME" --shell /bin/bash "$CI_USER"
    ci_group="$(id -gn "$CI_USER")"
    usermod -aG docker "$CI_USER"

    getent group ubuntu-build >/dev/null || groupadd --system ubuntu-build
    usermod -aG ubuntu-build "$CI_USER"
    if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != root ]] &&
        id "$SUDO_USER" >/dev/null 2>&1; then
        usermod -aG ubuntu-build "$SUDO_USER"
    fi
    install -d -g ubuntu-build -m 2775 "$BUILD_OUTPUT_DIR"
    install -d -g ubuntu-build -m 2775 \
        "$BUILD_OUTPUT_DIR/work" "$BUILD_OUTPUT_DIR/cache" \
        "$BUILD_OUTPUT_DIR/images" "$BUILD_OUTPUT_DIR/packages" \
        "$BUILD_OUTPUT_DIR/platform-assets" "$BUILD_OUTPUT_DIR/releases"

    install -d -m 0755 "$UBUNTU_CI_CONFIG_DIR"
    install -d -o 1000 -g 1000 -m 0750 "$FORGEJO_DATA_DIR"
    compose_yaml >"$FORGEJO_COMPOSE"
    chmod 0644 "$FORGEJO_COMPOSE"
    "${compose[@]}" -f "$FORGEJO_COMPOSE" up -d
    for _ in $(seq 1 60); do
        if curl --fail --silent http://127.0.0.1:3000/api/healthz >/dev/null; then
            break
        fi
        sleep 2
    done
    curl --fail --silent --show-error http://127.0.0.1:3000/api/healthz >/dev/null

    credential_file="$UBUNTU_CI_CONFIG_DIR/forgejo-admin.env"
    if [[ ! -f "$credential_file" ]]; then
        password="$(openssl rand -base64 24 | tr -d '/+=')"
        umask 077
        printf 'FORGEJO_ADMIN_USER=%q\nFORGEJO_ADMIN_PASSWORD=%q\n' \
            "$FORGEJO_ADMIN_USER" "$password" >"$credential_file"
    fi
    # shellcheck disable=SC1090
    source "$credential_file"
    if ! docker exec --user git forgejo forgejo admin user list |
        awk '{print $2}' | grep -qx "$FORGEJO_ADMIN_USER"; then
        docker exec --user git forgejo forgejo admin user create \
            --username "$FORGEJO_ADMIN_USER" \
            --password "$FORGEJO_ADMIN_PASSWORD" \
            --email "$FORGEJO_ADMIN_EMAIL" --admin --must-change-password=false
    fi
    repo_status="$(curl -sS -o /dev/null -w '%{http_code}' \
        -u "$FORGEJO_ADMIN_USER:$FORGEJO_ADMIN_PASSWORD" \
        "http://127.0.0.1:3000/api/v1/repos/${FORGEJO_ADMIN_USER}/ubuntu")"
    if [[ "$repo_status" == 404 ]]; then
        curl --fail --silent --show-error \
            -u "$FORGEJO_ADMIN_USER:$FORGEJO_ADMIN_PASSWORD" \
            -H 'Content-Type: application/json' \
            -d '{"name":"ubuntu","private":true,"auto_init":false}' \
            http://127.0.0.1:3000/api/v1/user/repos >/dev/null
    fi

    runner_url="https://code.forgejo.org/forgejo/runner/releases/download/v${RUNNER_VERSION}/forgejo-runner-${RUNNER_VERSION}-linux-$(host_arch)"
    if ! command -v forgejo-runner >/dev/null 2>&1 ||
        ! forgejo-runner --version 2>/dev/null | grep -qF "$RUNNER_VERSION"; then
        tmp_dir="$(mktemp -d)"
        curl --fail --location --retry 5 --retry-all-errors --connect-timeout 15 \
            "$runner_url" -o "$tmp_dir/forgejo-runner"
        curl --fail --location --retry 5 --retry-all-errors --connect-timeout 15 \
            "${runner_url}.asc" -o "$tmp_dir/forgejo-runner.asc"
        gpg_fingerprint=EB114F5E6C0DC2BCDD183550A4B61A2DC5923710
        if ! gpg --batch --list-keys "$gpg_fingerprint" >/dev/null 2>&1; then
            timeout 120 gpg --batch --keyserver-options timeout=30 \
                --keyserver hkps://keys.openpgp.org \
                --recv-keys "$gpg_fingerprint" ||
                timeout 120 gpg --batch --keyserver-options timeout=30 \
                    --keyserver hkps://keyserver.ubuntu.com \
                    --recv-keys "$gpg_fingerprint"
        fi
        gpg --batch --verify "$tmp_dir/forgejo-runner.asc" \
            "$tmp_dir/forgejo-runner"
        install -m 0755 "$tmp_dir/forgejo-runner" /usr/local/bin/forgejo-runner
        rm -rf -- "$tmp_dir"
    fi

    install -d -o "$CI_USER" -g "$ci_group" -m 0750 \
        "$CI_HOME/.config" "$CI_HOME/.cache" "$RUNNER_DIR" \
        "$CI_HOME/.cache/act" "$CI_HOME/.cache/forgejo-runner"
    runner_config >"$RUNNER_DIR/config.yml"
    chown "$CI_USER:$ci_group" "$RUNNER_DIR/config.yml"
    chmod 0640 "$RUNNER_DIR/config.yml"
    if [[ ! -s "$RUNNER_DIR/.runner" ]]; then
        token="$(docker exec --user git forgejo forgejo forgejo-cli actions generate-runner-token | tail -n1)"
        (
            cd "$RUNNER_DIR"
            runuser -u "$CI_USER" -- env HOME="$CI_HOME" \
                forgejo-runner register --no-interactive \
                    --instance http://127.0.0.1:3000 --token "$token" \
                    --name "$(hostname)-$(host_arch)" --labels "$RUNNER_LABEL"
        )
        chown "$CI_USER:$ci_group" "$RUNNER_DIR/.runner"
        chmod 0600 "$RUNNER_DIR/.runner"
    fi

    cat >/etc/systemd/system/forgejo-runner.service <<EOF
[Unit]
Description=Forgejo Actions Runner
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=simple
User=${CI_USER}
Group=${ci_group}
WorkingDirectory=${RUNNER_DIR}
Environment="BUILD_OUTPUT_DIR=${BUILD_OUTPUT_DIR}"
ExecStartPre=/usr/bin/bash -c 'for _ in {1..120}; do /usr/bin/curl --fail --silent http://127.0.0.1:3000/api/healthz >/dev/null && exit 0; /usr/bin/sleep 1; done; exit 1'
ExecStart=/usr/local/bin/forgejo-runner daemon -c ${RUNNER_DIR}/config.yml
Restart=always
RestartSec=5
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
EOF
    printf '%s ALL=(ALL) NOPASSWD: ALL\n' "$CI_USER" \
        >/etc/sudoers.d/90-ubuntu-ci-runner
    chmod 0440 /etc/sudoers.d/90-ubuntu-ci-runner
    visudo -cf /etc/sudoers.d/90-ubuntu-ci-runner >/dev/null
    systemctl daemon-reload
    systemctl enable --now forgejo-runner.service
}

check_host() {
    local distribution

    [[ "$(stat -c %a /tmp)" == 1777 ]] || die "/tmp mode must be 1777"
    sudo -u "$CI_USER" sh -c 'probe=$(mktemp) && rm -f -- "$probe"' ||
        die "CI runner cannot create temporary files"
    [[ -d /sys/kernel/security/apparmor ]] ||
        die "AppArmor securityfs is unavailable"
    systemctl is-active --quiet apparmor.service || die "AppArmor is not active"
    systemctl is-active --quiet apt-cacher-ng.service || die "apt-cacher-ng is not active"
    systemctl is-active --quiet docker.service || die "Docker is not active"
    systemctl is-active --quiet forgejo-runner.service || die "Forgejo runner is not active"
    systemctl show forgejo-runner.service --property=Environment --value |
        grep -Fq "BUILD_OUTPUT_DIR=${BUILD_OUTPUT_DIR}" ||
        die "Forgejo runner does not use BUILD_OUTPUT_DIR=${BUILD_OUTPUT_DIR}"
    curl --fail --silent --show-error http://127.0.0.1:3142/acng-report.html >/dev/null ||
        die "apt-cacher-ng health check failed"
    curl --fail --silent --show-error http://127.0.0.1:3000/api/healthz >/dev/null ||
        die "Forgejo health check failed"
    snap list ubuntu-image >/dev/null 2>&1 || die "ubuntu-image snap is not installed"
    [[ -x /snap/bin/ubuntu-image ]] || die "ubuntu-image command is unavailable"
    command -v node >/dev/null || die "Node.js is unavailable for Forgejo actions"
    sudo -u "$CI_USER" node --version >/dev/null ||
        die "Node.js cannot run as the CI account"
    sudo -u "$CI_USER" /snap/bin/ubuntu-image --version >/dev/null ||
        die "ubuntu-image cannot run as the CI account"
    id "$CI_USER" >/dev/null 2>&1 || die "CI account is unavailable: $CI_USER"
    sudo -u "$CI_USER" sudo -n true || die "CI runner lacks non-interactive sudo"
    [[ -d "$BUILD_OUTPUT_DIR" ]] ||
        die "build output directory is unavailable: $BUILD_OUTPUT_DIR"
    sudo -u "$CI_USER" sh -c \
        'probe=$(mktemp "$1/.write-test.XXXXXX") && rm -f -- "$probe"' \
        sh "$BUILD_OUTPUT_DIR" ||
        die "CI runner cannot write build output directory: $BUILD_OUTPUT_DIR"
    if [[ "$(host_arch)" == amd64 ]]; then
        command -v qemu-aarch64-static >/dev/null || die "qemu-aarch64-static is unavailable"
    fi

    echo "Ubuntu build and Forgejo host ready"
    echo "  architecture: $(uname -m)"
    distribution="$(sed -n 's/^PRETTY_NAME=//p' /etc/os-release)"
    distribution="${distribution#\"}"
    distribution="${distribution%\"}"
    echo "  distribution: ${distribution}"
    echo "  ubuntu-image: $(sudo -u "$CI_USER" /snap/bin/ubuntu-image --version)"
    echo "  Forgejo:      http://${FORGEJO_PUBLIC_HOST}:3000/${FORGEJO_ADMIN_USER}/ubuntu"
    echo "  Git SSH:      ssh://git@${FORGEJO_PUBLIC_HOST}:2222/${FORGEJO_ADMIN_USER}/ubuntu.git"
    echo "  CI runner:    $(forgejo-runner --version)"
    echo "  build output: ${BUILD_OUTPUT_DIR}"
}

if [[ "$MODE" == setup ]]; then
    install_host_packages
    ensure_ci_account
    configure_docker_storage
    configure_docker_proxy
    systemctl enable --now docker.service
    configure_apt_cache
    install_ubuntu_image
    repair_snap_confine_caps
    install_forgejo
fi

check_host
