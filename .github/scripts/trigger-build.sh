#!/bin/bash
# ==========================================================================
# trigger-build.sh — Trigger GitHub Actions + wait + pull artifacts
#
# Flow:
#   1. Read ubuntu/.env → get ARM64 target IP/password + GitHub repo
#   2. Test SSH to ARM64 target (verify it's ready for deployment)
#   3. Push code to GitHub → triggers workflow_dispatch
#   4. Poll GitHub API / gh CLI for workflow completion
#   5. Download rootfs.tar.gz + update.img to ubuntu/artifacts/
#
# Usage:
#   bash .github/scripts/trigger-build.sh                          # use .env defaults
#   bash .github/scripts/trigger-build.sh server                   # build server variant
#   bash .github/scripts/trigger-build.sh desktop noble            # variant + series
#   DRY_RUN=1 bash .github/scripts/trigger-build.sh                # test without triggering
# ==========================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)"
ENV_FILE="${REPO_ROOT}/ubuntu/.env"
ARTIFACTS_DIR="${REPO_ROOT}/ubuntu/artifacts"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
NC='\033[0m'
info()  { echo -e "${GREEN}[TRIGGER]${NC} $*"; }
warn()  { echo -e "${YELLOW}[TRIGGER]${NC} $*"; }
error() { echo -e "${RED}[TRIGGER]${NC} $*"; exit 1; }
step()  { echo ""; echo -e "${CYAN}━━━ $* ━━━${NC}"; }

# ─── Load config ───────────────────────────────────────────────────────────
if [[ -f "${ENV_FILE}" ]]; then
    source "${ENV_FILE}"
else
    error ".env not found at ${ENV_FILE}"
fi

# ─── CLI args ──────────────────────────────────────────────────────────────
VARIANT="${1:-${UBUNTU_VARIANT:-desktop}}"
SERIES="${2:-${UBUNTU_SERIES:-noble}}"
DRY_RUN="${DRY_RUN:-0}"

# ─── Validate required config ──────────────────────────────────────────────
if [[ -z "${BUILD_HOST:-}" ]]; then
    error "BUILD_HOST not set in .env"
fi
if [[ -z "${BUILD_USER:-}" ]]; then
    error "BUILD_USER not set in .env"
fi
if [[ -z "${BUILD_PASS:-}" ]]; then
    warn "BUILD_PASS not set in .env — SSH may fail if key-based auth not configured"
fi

REMOTE="${BUILD_USER}@${BUILD_HOST}"

echo ""
echo "============================================================"
echo -e " ${BLUE}Ubuntu Image Build — CI Trigger${NC}"
echo "  ARM64 Target: ${REMOTE}"
echo "  Variant:      ${VARIANT}"
echo "  Series:       ${SERIES}"
echo "  GitHub Repo:  ${GITHUB_REPO:-auto-detect}"
echo "  Dry Run:      ${DRY_RUN}"
echo "============================================================"
echo ""

# ═══════════════════════════════════════════════════════════════════════════
# Phase 1: Test ARM64 target connectivity
# ═══════════════════════════════════════════════════════════════════════════
step "Phase 1/5: Testing ARM64 target (${REMOTE})"

SSHPASS_BIN=""
if [[ -n "${BUILD_PASS:-}" ]] && command -v sshpass &>/dev/null; then
    SSHPASS_BIN="sshpass -p ${BUILD_PASS}"
elif [[ -n "${BUILD_PASS:-}" ]]; then
    warn "sshpass not installed. Install: sudo apt-get install sshpass"
    warn "Trying key-based SSH..."
fi

ssh_test() {
    ${SSHPASS_BIN} ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
        -o BatchMode=yes "${REMOTE}" "echo SSH_OK" 2>/dev/null
}

if SSH_RESULT=$(ssh_test 2>&1); then
    REMOTE_ARCH=$(${SSHPASS_BIN} ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
        "${REMOTE}" "uname -m" 2>/dev/null)
    REMOTE_OS=$(${SSHPASS_BIN} ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
        "${REMOTE}" "cat /etc/os-release 2>/dev/null | grep '^PRETTY_NAME' | cut -d= -f2 | tr -d '\"'" 2>/dev/null || echo 'unknown')
    info "Connected: ${REMOTE_OS} / ${REMOTE_ARCH}"

    if [[ "${REMOTE_ARCH}" != "aarch64" && "${REMOTE_ARCH}" != "arm64" ]]; then
        error "Target is ${REMOTE_ARCH}, not ARM64! Wrong target?"
    fi
else
    echo ""
    error "Cannot SSH to ${REMOTE}!
  Check:
    1. Target is powered on and connected
    2. IP address: ${BUILD_HOST}
    3. User/password in ubuntu/.env
    4. Or set up SSH key: ssh-copy-id ${REMOTE}"
fi

# Quick check: does target have ubuntu-image or can it be installed?
${SSHPASS_BIN} ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 "${REMOTE}" \
    "/snap/bin/ubuntu-image version 2>/dev/null && echo 'ubuntu-image: OK' || echo 'ubuntu-image: NEEDS_INSTALL'" 2>/dev/null

info "ARM64 target ready."

# ═══════════════════════════════════════════════════════════════════════════
# Phase 2: Detect / validate GitHub repo
# ═══════════════════════════════════════════════════════════════════════════
step "Phase 2/5: GitHub repository setup"

# Detect GitHub repo from git remote
if [[ -z "${GITHUB_REPO:-}" ]]; then
    if git -C "${REPO_ROOT}" remote get-url origin &>/dev/null; then
        RAW_URL=$(git -C "${REPO_ROOT}" remote get-url origin)
        # Handle both HTTPS and SSH formats:
        # https://github.com/owner/repo.git → owner/repo
        # git@github.com:owner/repo.git      → owner/repo
        if echo "${RAW_URL}" | grep -q 'github\.com'; then
            GITHUB_REPO=$(echo "${RAW_URL}" | sed -E 's|.*github\.com[/:](.*)|\1|' | sed 's/\.git$//')
            info "Detected repo: ${GITHUB_REPO}"
        fi
    fi

    if [[ -z "${GITHUB_REPO:-}" ]]; then
        warn "Cannot detect GitHub repo. Set GITHUB_REPO in ubuntu/.env"
        warn "Example: GITHUB_REPO=\"myorg/mylr3576-sdk\""
        warn ""
        warn "Skipping GitHub trigger — proceeding with local packaging only."
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# Phase 3: Push code to GitHub → trigger workflow
# ═══════════════════════════════════════════════════════════════════════════
step "Phase 3/5: Triggering GitHub Actions workflow"

WORKFLOW_YML="${GITHUB_WORKFLOW:-ubuntu-build.yml}"
BRANCH="${GITHUB_REF:-lr3576_v2.1}"

trigger_workflow() {
    local repo="$1"
    local workflow="$2"
    local branch="$3"
    local variant="$4"
    local series="$5"

    if command -v gh &>/dev/null && gh auth status &>/dev/null 2>&1; then
        # ── Use gh CLI (preferred) ──────────────────────────────────────
        info "Triggering via gh CLI: ${workflow} on ${branch}"
        gh workflow run "${workflow}" \
            --repo "${repo}" \
            --ref "${branch}" \
            -f mode=remote \
            -f variant="${variant}" \
            -f series="${series}"
        echo ""
        info "Workflow triggered via gh CLI."
        echo "  Monitor: gh run watch --repo ${repo}"
        return 0
    elif [[ -n "${GITHUB_TOKEN:-}" ]]; then
        # ── Use GitHub API directly ─────────────────────────────────────
        info "Triggering via GitHub API (token)..."
        local api_url="https://api.github.com/repos/${repo}/actions/workflows/${workflow}/dispatches"
        local payload=$(jq -n \
            --arg ref "${branch}" \
            --arg mode "remote" \
            --arg variant "${variant}" \
            --arg series "${series}" \
            '{ref: $ref, inputs: {mode: $mode, variant: $variant, series: $series}}')

        local http_code
        http_code=$(curl -s -o /dev/null -w "%{http_code}" \
            -X POST "${api_url}" \
            -H "Authorization: Bearer ${GITHUB_TOKEN}" \
            -H "Accept: application/vnd.github.v3+json" \
            -d "${payload}")

        if [[ "${http_code}" == "204" ]]; then
            info "Workflow triggered via API (HTTP ${http_code})."
            return 0
        else
            error "GitHub API returned HTTP ${http_code}. Check GITHUB_TOKEN."
        fi
    else
        # ── No trigger method available ─────────────────────────────────
        warn "Neither 'gh' CLI nor GITHUB_TOKEN available."
        warn "  Option A: Run 'gh auth login' once"
        warn "  Option B: Set GITHUB_TOKEN in ubuntu/.env"
        warn "  Option C: Push manually: git push origin ${branch}"
        warn ""
        warn "Skipping GitHub trigger — falling back to local packaging."
        return 1
    fi
}

if [[ -n "${GITHUB_REPO:-}" ]]; then
    if [[ "${DRY_RUN}" == "1" ]]; then
        info "DRY_RUN=1 — skipping workflow trigger."
        info "Would trigger: ${GITHUB_WORKFLOW} on ${BRANCH}"
        info "  variant=${VARIANT} series=${SERIES}"
    else
        trigger_workflow "${GITHUB_REPO}" "${WORKFLOW_YML}" "${BRANCH}" "${VARIANT}" "${SERIES}" || true
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# Phase 4: Wait for workflow completion + download artifacts
# ═══════════════════════════════════════════════════════════════════════════
step "Phase 4/5: Waiting for GitHub Actions to finish"

wait_and_download() {
    local repo="$1"
    local variant="$2"
    local series="$3"
    local workflow="$4"

    if ! command -v gh &>/dev/null || ! gh auth status &>/dev/null 2>&1; then
        warn "gh CLI not available — cannot poll workflow status."
        warn "Check manually: https://github.com/${repo}/actions"
        return 1
    fi

    # Get the latest workflow run ID
    info "Finding latest ${workflow} run..."
    local run_id
    for i in $(seq 1 6); do
        run_id=$(gh run list --repo "${repo}" --workflow "${workflow}" \
            --limit 1 --json databaseId --jq '.[0].databaseId' 2>/dev/null || echo "")
        if [[ -n "${run_id}" && "${run_id}" != "null" ]]; then
            break
        fi
        sleep 10
    done

    if [[ -z "${run_id}" || "${run_id}" == "null" ]]; then
        warn "Cannot find workflow run. Check: gh run list --repo ${repo}"
        return 1
    fi

    info "Watching run: https://github.com/${repo}/actions/runs/${run_id}"
    echo ""

    # Watch with timeout (max 4 hours for remote build)
    if ! gh run watch "${run_id}" --repo "${repo}" --exit-status 2>/dev/null; then
        # gh run watch exits 1 if no run found, but the run might still succeed
        warn "gh run watch returned error — checking final status..."

        # Wait manually with polling
        for i in $(seq 1 240); do  # 240 * 60s = 4 hours max
            local status
            status=$(gh run view "${run_id}" --repo "${repo}" \
                --json status,conclusion --jq '"\(.status)|\(.conclusion)"' 2>/dev/null || echo "unknown|unknown")

            local run_status="${status%%|*}"
            local run_conclusion="${status##*|}"

            printf "\r  [%3d min] status: %-12s  conclusion: %-12s" "$i" "${run_status}" "${run_conclusion}"

            if [[ "${run_status}" == "completed" ]]; then
                echo ""
                if [[ "${run_conclusion}" == "success" ]]; then
                    info "Build succeeded!"
                    break
                else
                    error "Build failed (conclusion: ${run_conclusion})."
                fi
            fi
            sleep 60
        done
    fi

    # Download artifacts
    info "Downloading artifacts..."
    mkdir -p "${ARTIFACTS_DIR}"

    local artifact_dir
    artifact_dir=$(mktemp -d /tmp/gh-artifacts-XXXXXX)

    gh run download "${run_id}" --repo "${repo}" --dir "${artifact_dir}" 2>&1 || {
        warn "Artifact download failed."
        rm -rf "${artifact_dir}"
        return 1
    }

    # Find and copy rootfs.tar.gz + update.img
    local found=0
    while IFS= read -r -d '' f; do
        local fname
        fname=$(basename "${f}")
        info "  Found: ${fname} ($(du -h "${f}" | cut -f1))"
        cp "${f}" "${ARTIFACTS_DIR}/"
        found=$((found + 1))
    done < <(find "${artifact_dir}" \( -name 'rootfs.tar.gz' -o -name 'update.img' -o -name 'ubuntu-image.log' \) -type f -print0 2>/dev/null)

    rm -rf "${artifact_dir}"

    if [[ ${found} -gt 0 ]]; then
        info "${found} artifact(s) downloaded to ${ARTIFACTS_DIR}/"
        return 0
    else
        warn "No matching artifacts found."
        return 1
    fi
}

if [[ -n "${GITHUB_REPO:-}" && "${DRY_RUN}" != "1" ]]; then
    wait_and_download "${GITHUB_REPO}" "${VARIANT}" "${SERIES}" "${WORKFLOW_YML}" || {
        warn "Artifact download failed. Run locally:"
        warn "  bash .github/scripts/deploy-to-debian.sh ${BUILD_HOST} ${VARIANT}"
    }
fi

# ═══════════════════════════════════════════════════════════════════════════
# Phase 5: Summary
# ═══════════════════════════════════════════════════════════════════════════
step "Phase 5/5: Summary"

echo ""
echo "============================================================"
info "Trigger build complete!"
echo ""
echo "  Artifacts: ${ARTIFACTS_DIR}/"
ls -lh "${ARTIFACTS_DIR}/"rootfs.tar.gz 2>/dev/null && echo ""
ls -lh "${ARTIFACTS_DIR}/"update.img 2>/dev/null && echo ""
ls -lh "${ARTIFACTS_DIR}/"ubuntu-image.log 2>/dev/null && echo ""

if [[ -f "${ARTIFACTS_DIR}/update.img" ]]; then
    echo ""
    info "Flash to target:"
    info "  sudo upgrade_tool uf ${ARTIFACTS_DIR}/update.img"
fi
echo "============================================================"
