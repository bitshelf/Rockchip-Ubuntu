#!/usr/bin/env bash
set -Eeuo pipefail

# CI invokes mount tests as root; do not leave root-owned Python caches.
export PYTHONDONTWRITEBYTECODE=1

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

[[ $# -eq 0 || ( $# -eq 1 && "${1:-}" == --syntax-only ) ]] || {
    echo 'usage: scripts/check-source.sh [--syntax-only]' >&2; exit 2;
}

while IFS= read -r -d '' script; do
    case "$(head -n1 "$script")" in
        '#!'*bash*) bash -n "$script" ;;
        '#!'*'/sh'*|'#!'*'env sh'*) sh -n "$script" ;;
    esac
done < <(find "$PROJECT_DIR/scripts" "$PROJECT_DIR/tests" "$PROJECT_DIR/config" \
    "$PROJECT_DIR/package" -type f -print0 | sort -z)

if [[ "${1:-}" == --syntax-only ]]; then
    echo 'Shell syntax checks passed'; exit 0;
fi

while IFS= read -r -d '' test_script; do
    bash "$test_script"
done < <(find "$PROJECT_DIR/tests/host" -maxdepth 1 -type f \
    -name 'test-*.sh' -print0 | sort -z)

"$PROJECT_DIR/scripts/setup-build-host.sh" --self-test
echo "Source checks passed"
