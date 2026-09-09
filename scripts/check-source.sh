#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

bash -n "$0"
bash -n "${PROJECT_DIR}/tests/host/test-repository-contract.sh"
bash -n "${PROJECT_DIR}/scripts/setup-build-host.sh"
bash -n "${PROJECT_DIR}/build.sh"
bash -n "${PROJECT_DIR}/scripts/build-server.sh"
bash -n "${PROJECT_DIR}/scripts/stage-sdk-assets.sh"
bash -n "${PROJECT_DIR}/tests/host/test-stage-sdk-assets.sh"
bash -n "${PROJECT_DIR}/scripts/cross-build-env.sh"
bash -n "${PROJECT_DIR}/containers/cross-build/configure-apt.sh"
bash -n "${PROJECT_DIR}/containers/cross-build/entrypoint.sh"
bash -n "${PROJECT_DIR}/tests/host/test-cross-build-env.sh"
bash "${PROJECT_DIR}/tests/host/test-repository-contract.sh"
bash "${PROJECT_DIR}/tests/host/test-build-server.sh"
bash "${PROJECT_DIR}/tests/host/test-stage-sdk-assets.sh"
bash "${PROJECT_DIR}/tests/host/test-cross-build-env.sh"
"${PROJECT_DIR}/scripts/setup-build-host.sh" --self-test

echo "Source checks passed"
