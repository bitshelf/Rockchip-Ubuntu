#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

bash -n "$0"
bash -n "${PROJECT_DIR}/tests/host/test-repository-contract.sh"
bash -n "${PROJECT_DIR}/scripts/setup-build-host.sh"
bash "${PROJECT_DIR}/tests/host/test-repository-contract.sh"
"${PROJECT_DIR}/scripts/setup-build-host.sh" --self-test

echo "Source checks passed"
