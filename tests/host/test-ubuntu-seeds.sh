#!/usr/bin/env bash
set -Eeuo pipefail
project="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
export SEED_TEST_ROOT="$tmp" REAL_SEED_GIT="$(command -v git)"
export UBUNTU_SERIES=fixture-series
mkdir -p "$tmp/bin" "$tmp/repos" "$tmp/cache"
for name in ubuntu platform; do
    "$REAL_SEED_GIT" init -q --initial-branch="$UBUNTU_SERIES" "$tmp/repos/$name"
    printf 'minimal:\n' >"$tmp/repos/$name/STRUCTURE"
    printf ' * bash\n' >"$tmp/repos/$name/minimal"
    "$REAL_SEED_GIT" -C "$tmp/repos/$name" add .
    "$REAL_SEED_GIT" -C "$tmp/repos/$name" -c user.name=fixture \
        -c user.email=fixture@localhost commit -qm fixture
done
cat >"$tmp/bin/wget" <<'WGET'
#!/usr/bin/env bash
set -eu
for arg; do
    case "$arg" in --directory-prefix=*) target="${arg#*=}";; esac
done
if [[ "${SEED_TEST_ARCHIVE:-fail}" == incomplete ]]; then exit 0; fi
if [[ "${SEED_TEST_ARCHIVE:-fail}" == success ]]; then
    printf 'minimal:\n' >"$target/STRUCTURE"
    printf ' * bash\n' >"$target/minimal"
    exit 0
fi
printf 'partial untrusted download\n' >"$target/partial-file"
exit 8
WGET
cat >"$tmp/bin/git" <<'GIT'
#!/usr/bin/env python3
import os, sys
args = sys.argv[1:]
prefix = 'https://git.launchpad.net/~ubuntu-core-dev/ubuntu-seeds/+git/'
for i, arg in enumerate(args):
    if arg.startswith(prefix):
        seed = arg[len(prefix):]
        assert seed in ('ubuntu', 'platform'), 'unexpected official source'
        args[i] = 'file://' + os.environ['SEED_TEST_ROOT'] + '/repos/' + seed
        with open(os.environ['SEED_TEST_ROOT']+'/git-fetches', 'a') as f:
            f.write(seed+'\n')
os.execv(os.environ['REAL_SEED_GIT'], [os.environ['REAL_SEED_GIT'], *args])
GIT
chmod +x "$tmp/bin/"*
export PATH="$tmp/bin:$PATH"
SEED_CACHE_ROOT="$tmp/cache"
info() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
source "$project/scripts/lib/ubuntu-seeds.sh"

# Successful HTTP mirror requires no Git network access.
export SEED_TEST_ARCHIVE=incomplete
if (cache_seed ubuntu) >"$tmp/incomplete-http.log" 2>&1; then
    echo 'FAIL: incomplete HTTP seed was accepted' >&2; exit 1
fi
[[ ! -e "$tmp/cache/ubuntu" && ! -e "$tmp/git-fetches" ]]
export SEED_TEST_ARCHIVE=success
cache_seed ubuntu
[[ -s "$tmp/cache/ubuntu/STRUCTURE" && ! -e "$tmp/git-fetches" ]]
rm -rf "$tmp/cache/ubuntu"

# An HTTP failure must fetch the exact official release branch, discard partial
# files and preserve the upstream commit for provenance, for both seed sources.
export SEED_TEST_ARCHIVE=fail
for name in ubuntu platform; do
    expected="$("$REAL_SEED_GIT" -C "$tmp/repos/$name" rev-parse HEAD)"
    cache_seed "$name"
    [[ "$(git -C "$tmp/cache/$name" rev-parse HEAD)" == "$expected" ]]
    [[ ! -e "$tmp/cache/$name/partial-file" ]]
    [[ "$(git -C "$tmp/cache/$name" config --local user.email)" == builder@localhost ]]
done
fetches="$(wc -l <"$tmp/git-fetches")"
cache_seed ubuntu
[[ "$(wc -l <"$tmp/git-fetches")" == "$fetches" ]]

# Missing series and incomplete Git trees fail closed; never reuse another
# branch or install a partially downloaded seed cache.
rm -rf "$tmp/cache/ubuntu"
if (UBUNTU_SERIES=missing-series; cache_seed ubuntu) >"$tmp/missing.log" 2>&1; then
    echo 'FAIL: missing official release branch was accepted' >&2; exit 1
fi
[[ ! -e "$tmp/cache/ubuntu" ]]
rm "$tmp/repos/ubuntu/STRUCTURE"
"$REAL_SEED_GIT" -C "$tmp/repos/ubuntu" add -u
"$REAL_SEED_GIT" -C "$tmp/repos/ubuntu" -c user.name=fixture \
    -c user.email=fixture@localhost commit -qm incomplete
if (cache_seed ubuntu) >"$tmp/incomplete.log" 2>&1; then
    echo 'FAIL: incomplete official seed was accepted' >&2; exit 1
fi
[[ ! -e "$tmp/cache/ubuntu" ]]
echo 'Seed mirror, official Git fallback, cache and failure checks passed'
