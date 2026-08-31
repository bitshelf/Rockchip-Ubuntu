#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

bash -n "$0"
bash -n "${PROJECT_DIR}/tests/host/test-repository-contract.sh"
bash -n "${PROJECT_DIR}/scripts/setup-build-host.sh"
bash -n "${PROJECT_DIR}/build.sh"
bash -n "${PROJECT_DIR}/scripts/build-server.sh"
bash "${PROJECT_DIR}/tests/host/test-repository-contract.sh"
bash "${PROJECT_DIR}/tests/host/test-build-server.sh"
"${PROJECT_DIR}/scripts/setup-build-host.sh" --self-test

echo "Source checks passed"
