#!/usr/bin/env bash
# Shared by the rootfs builder and its offline seed-fetch tests.
cache_seed() {
    local seed_name="$1" archive_url stage repo git_url
    [[ "$seed_name" == ubuntu || "$seed_name" == platform ]] ||
        die "unsupported upstream seed: $seed_name"
    repo="${SEED_CACHE_ROOT}/${seed_name}"
    [[ -s "${repo}/STRUCTURE" && -d "${repo}/.git" ]] && return
    stage="$(mktemp -d "${SEED_CACHE_ROOT}/.${seed_name}.XXXXXX")"
    archive_url="https://ubuntu-archive-team.ubuntu.com/seeds/${seed_name}.${UBUNTU_SERIES}/"
    git_url="https://git.launchpad.net/~ubuntu-core-dev/ubuntu-seeds/+git/${seed_name}"
    info "Cache Canonical ${seed_name}.${UBUNTU_SERIES} seed"
    if env http_proxy="${HTTP_PROXY:-}" https_proxy="${HTTPS_PROXY:-}" \
        no_proxy="${NO_PROXY:-}" wget --no-verbose --mirror --no-parent \
        --no-host-directories --cut-dirs=2 --reject='index.html*' \
        --timeout=30 --tries=3 --retry-connrefused \
        --retry-on-http-error=429,500,502,503,504 --waitretry=2 \
        --directory-prefix="$stage" "$archive_url"; then
        [[ -s "${stage}/STRUCTURE" ]] || {
            rm -rf -- "$stage"
            die "incomplete ${seed_name} seed cache"
        }
        git -C "$stage" init --quiet --initial-branch="$UBUNTU_SERIES"
        git -C "$stage" config user.email builder@localhost
        git -C "$stage" config user.name "Ubuntu Image Builder"
        git -C "$stage" add -A
        git -C "$stage" commit --quiet -m "Import Canonical ${seed_name}.${UBUNTU_SERIES} seed"
    else
        # Never mix a partial archive mirror with a Git checkout or switch series.
        rm -rf -- "$stage"
        info "Seed mirror unavailable; use official Git ${seed_name}:${UBUNTU_SERIES}"
        if ! timeout 180 env http_proxy="${HTTP_PROXY:-}" https_proxy="${HTTPS_PROXY:-}" \
            no_proxy="${NO_PROXY:-}" git -c http.lowSpeedLimit=1 -c http.lowSpeedTime=30 \
            clone --quiet --depth=1 --single-branch --branch "$UBUNTU_SERIES" \
            -- "$git_url" "$stage"; then
            rm -rf -- "$stage"
            die "cannot download ${seed_name}.${UBUNTU_SERIES} from its mirror or official Git"
        fi
        git -C "$stage" config user.email builder@localhost
        git -C "$stage" config user.name "Ubuntu Image Builder"
        [[ -s "${stage}/STRUCTURE" ]] || {
            rm -rf -- "$stage"
            die "incomplete official Git ${seed_name} seed"
        }
        info "Official seed commit: $(git -C "$stage" rev-parse HEAD)"
    fi
    rm -rf -- "$repo"
    mv "$stage" "$repo"
}
