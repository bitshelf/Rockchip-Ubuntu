#!/usr/bin/env bash
set -Eeuo pipefail

RKNPU_LOOPS=200
RKNPU_MAX_LATENCY_MS="${RKNPU_MAX_LATENCY_MS:-15}"
RKNPU_MIN_TOP1="${RKNPU_MIN_TOP1:-0.5}"
RKNPU_EXPECTED_TOP1_CLASS="${RKNPU_EXPECTED_TOP1_CLASS:-156}"

fail() { echo "FAIL: $*" >&2; exit 1; }

rknpu_model_directory() {
    local compatible
    compatible="$(tr '\0' '\n' </proc/device-tree/compatible 2>/dev/null || true)"
    case "$compatible" in
        *rockchip,rk3576*) printf 'RK3576\n' ;;
        *rockchip,rk3588*) printf 'RK3588\n' ;;
        *rockchip,rk3566*|*rockchip,rk3568*) printf 'RK3566_RK3568\n' ;;
        *rockchip,rk3562*) printf 'RK3562\n' ;;
        *rockchip,rv1126b*) printf 'RV1126B\n' ;;
        *) return 1 ;;
    esac
}

rknpu_render_node() {
    local render driver
    if [[ -c /dev/rknpu ]]; then
        printf '/dev/rknpu\n'
        return 0
    fi
    for render in /sys/class/drm/renderD*; do
        [[ -e "$render/device/driver" ]] || continue
        driver="$(basename "$(readlink -f "$render/device/driver")")"
        [[ "${driver,,}" == *rknpu* ]] || continue
        [[ -c "/dev/dri/${render##*/}" ]] || continue
        printf '/dev/dri/%s\n' "${render##*/}"
        return 0
    done
    return 1
}

rknpu_test_user() {
    local user uid shell
    if (( EUID != 0 )); then
        id -un
        return 0
    fi
    if [[ -n "${RKNPU_QA_USER:-}" ]]; then
        user="$RKNPU_QA_USER"
    elif [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != root ]]; then
        user="$SUDO_USER"
    elif [[ -s /var/lib/ubuntu-firstboot/customer-user ]]; then
        IFS= read -r user </var/lib/ubuntu-firstboot/customer-user || [[ -n "$user" ]]
    else
        while IFS=: read -r user _ uid _ _ _ shell; do
            (( uid >= 1000 && uid < 65534 )) || continue
            [[ "$shell" != */nologin && "$shell" != */false ]] || continue
            break
        done </etc/passwd
    fi
    [[ -n "${user:-}" && "$user" != root ]] || return 1
    id "$user" >/dev/null 2>&1 || return 1
    printf '%s\n' "$user"
}

rknpu_timing_values() {
    sed -n 's/^.*Elapse Time[[:space:]]*=[[:space:]]*\([0-9][0-9.]*\)[[:space:]]*ms.*$/\1/p'
}

rknpu_top1() {
    awk '
        /^---- Top5 ----/ { in_top=1; next }
        in_top && /^[[:space:]]*[0-9]+([.][0-9]+)?[[:space:]]+-[[:space:]]+[0-9]+[[:space:]]*$/ {
            print $1, $3
            exit
        }
    '
}

rknpu_validate_output() {
    local output="$1" expected="$2" top1 confidence class min_ms avg_ms max_ms
    local -a timings=()
    mapfile -t timings < <(rknpu_timing_values <<<"$output")
    [[ "${#timings[@]}" -eq "$expected" ]] || {
        echo "expected $expected timing samples, got ${#timings[@]}" >&2
        return 1
    }
    top1="$(rknpu_top1 <<<"$output")"
    read -r confidence class <<<"$top1"
    [[ "$class" == "$RKNPU_EXPECTED_TOP1_CLASS" ]] || {
        echo "expected top-1 class $RKNPU_EXPECTED_TOP1_CLASS, got ${class:-missing}" >&2
        return 1
    }
    awk -v value="${confidence:-0}" -v minimum="$RKNPU_MIN_TOP1" \
        'BEGIN { exit !(value + 0 >= minimum + 0) }' || {
        echo "top-1 confidence ${confidence:-missing} is below $RKNPU_MIN_TOP1" >&2
        return 1
    }
    read -r min_ms avg_ms max_ms < <(
        printf '%s\n' "${timings[@]}" | awk -v limit="$RKNPU_MAX_LATENCY_MS" '
            NR == 1 { min=$1; max=$1 }
            $1 <= 0 || $1 >= limit { bad=1 }
            $1 < min { min=$1 }
            $1 > max { max=$1 }
            { sum += $1 }
            END {
                if (bad || NR == 0) exit 1
                printf "%.2f %.2f %.2f\n", min, sum / NR, max
            }
        '
    ) || {
        echo "one or more inference samples are outside 0..${RKNPU_MAX_LATENCY_MS}ms" >&2
        return 1
    }
    printf 'RKNPU_SOAK_OK completed=%s expected=%s top1_class=%s top1=%s min_ms=%s avg_ms=%s max_ms=%s limit_ms=%s\n' \
        "$expected" "$expected" "$class" "$confidence" "$min_ms" "$avg_ms" \
        "$max_ms" "$RKNPU_MAX_LATENCY_MS"
}

rknpu_run_as_user() {
    local user="$1" model="$2" image="$3"
    if [[ "$(id -u)" == "$(id -u "$user")" ]]; then
        timeout 600 rknn_common_test "$model" "$image" "$RKNPU_LOOPS"
    else
        command -v runuser >/dev/null || return 1
        runuser -u "$user" -- timeout 600 rknn_common_test \
            "$model" "$image" "$RKNPU_LOOPS"
    fi
}

run_rknpu_qa() {
    local model_directory model image node user output marker
    [[ "$(uname -m)" == aarch64 ]] || fail "target is not ARM64"
    for package in librknnrt2 rknn-server rknn-models; do
        [[ "$(dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null)" == installed ]] ||
            fail "$package is not installed"
        apt-mark showhold | grep -Fxq "$package" || fail "$package is not held"
    done
    command -v rknn_common_test >/dev/null || fail "rknn_common_test is missing"
    ldd /usr/bin/rknn_common_test | grep -Eq 'librknnrt[.]so => /' ||
        fail "rknn_common_test cannot resolve librknnrt.so"
    systemctl is-active --quiet rknn-server.service || fail "rknn-server.service is not active"

    model_directory="$(rknpu_model_directory)" || fail "no model mapping for target compatible"
    model="/usr/share/model/$model_directory/mobilenet_v1.rknn"
    image=/usr/share/model/dog_224x224.jpg
    [[ -s "$model" && -s "$image" ]] || fail "RKNPU model or sample image is missing"
    node="$(rknpu_render_node)" || fail "RKNPU device node is missing"
    user="$(rknpu_test_user)" || fail "no non-root QA account is available"
    [[ "$(id -u "$user")" -ne 0 ]] || fail "RKNPU QA must use a non-root account"

    output="$(rknpu_run_as_user "$user" "$model" "$image" 2>&1)" || {
        printf '%s\n' "$output" >&2
        fail "non-root RKNPU inference failed for $user"
    }
    marker="$(rknpu_validate_output "$output" "$RKNPU_LOOPS")" || {
        printf '%s\n' "$output" >&2
        fail "RKNPU output did not meet the acceptance contract"
    }
    printf 'RKNPU_NONROOT_OK user=%s device=%s\n' "$user" "$node"
    printf '%s user=%s model=%s\n' "$marker" "$user" "$model_directory"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    [[ $# -eq 0 ]] || fail "usage: $0"
    run_rknpu_qa
fi
