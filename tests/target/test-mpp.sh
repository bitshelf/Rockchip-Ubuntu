#!/usr/bin/env bash
set -Eeuo pipefail

MPP_FRAMES=100
MPP_WIDTH=640
MPP_HEIGHT=360

fail() { echo "FAIL: $*" >&2; exit 1; }

mpp_encoded_frame_summary() {
    sed -n 's/^.*encoded frame[[:space:]]\+\([0-9]\+\).*$/\1/p' |
        sort -nu | awk '
            NR == 1 { first=$1 }
            { last=$1; count++ }
            END { print count + 0, first + 0, last + 0 }
        '
}

mpp_decoded_frame_count() {
    awk '/decode [0-9]+ frames/ {
        for (i = 1; i <= NF; i++) {
            if ($i == "decode") { print $(i + 1); exit }
        }
    }'
}

run_mpp_qa() {
    [[ "$(uname -m)" == aarch64 ]] || fail "target is not ARM64"
    [[ "$EUID" -eq 0 ]] || fail "MPP QA must run as root"
    [[ -c /dev/mpp_service ]] || fail "/dev/mpp_service is missing"
    [[ "$(stat -c %a /dev/mpp_service)" == 666 ]] ||
        fail "/dev/mpp_service is not accessible to system and desktop users"
    for package in librockchip-mpp1 librockchip-vpu0 rockchip-mpp-demos; do
        [[ "$(dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null)" == installed ]] ||
            fail "$package is not installed"
    done
    for tool in mpi_enc_test mpi_dec_test mpp_info_test stat timeout; do
        command -v "$tool" >/dev/null || fail "missing MPP QA tool: $tool"
    done
    ldconfig -p | grep -q 'librockchip_mpp.so.1' ||
        fail "librockchip_mpp is not in the dynamic linker cache"

    work_dir="$(mktemp -d "${MPP_TEST_TMP_ROOT:-/run}/mpp-qa.XXXXXX")"
    cleanup_mpp_qa() { rm -rf -- "$work_dir"; }
    trap cleanup_mpp_qa EXIT INT TERM
    bitstream="$work_dir/encoded.h264"
    decoded_yuv="$work_dir/decoded.yuv"
    encode_log="$work_dir/encode.log"
    decode_log="$work_dir/decode.log"

    if ! timeout 180 mpi_enc_test -w "$MPP_WIDTH" -h "$MPP_HEIGHT" -t 7 \
            -o "$bitstream" -n "$MPP_FRAMES" >"$encode_log" 2>&1; then
        tail -80 "$encode_log" >&2
        fail "MPP H.264 encoding failed"
    fi
    summary="$(mpp_encoded_frame_summary <"$encode_log")"
    read -r encoded_count encoded_first encoded_last <<<"$summary"
    [[ "$encoded_count" -eq "$MPP_FRAMES" && "$encoded_first" -eq 0 &&
       "$encoded_last" -eq $((MPP_FRAMES - 1)) ]] || {
        tail -80 "$encode_log" >&2
        fail "expected encoded frame IDs 0..$((MPP_FRAMES - 1)), got ${summary:-none}"
    }
    encoded_bytes="$(stat -c %s "$bitstream")"
    (( encoded_bytes > 4096 )) || fail "encoded H.264 stream is implausibly small"
    printf 'RKMPP_ENCODE_OK frames=%s bytes=%s\n' "$MPP_FRAMES" "$encoded_bytes"

    if ! timeout 180 mpi_dec_test -i "$bitstream" -t 7 -o "$decoded_yuv" \
            -n "$MPP_FRAMES" >"$decode_log" 2>&1; then
        tail -80 "$decode_log" >&2
        fail "MPP H.264 decoding failed"
    fi
    decoded_count="$(mpp_decoded_frame_count <"$decode_log")"
    [[ "$decoded_count" == "$MPP_FRAMES" ]] || {
        tail -80 "$decode_log" >&2
        fail "expected $MPP_FRAMES decoded frames, got ${decoded_count:-none}"
    }
    decoded_bytes="$(stat -c %s "$decoded_yuv")"
    (( decoded_bytes > 1048576 )) || fail "decoded YUV output is implausibly small"
    printf 'RKMPP_DECODE_OK frames=%s bytes=%s\n' "$MPP_FRAMES" "$decoded_bytes"
    printf 'MPP_SMOKE_OK frames=%s codec=h264 size=%sx%s\n' \
        "$MPP_FRAMES" "$MPP_WIDTH" "$MPP_HEIGHT"

    cleanup_mpp_qa
    trap - EXIT INT TERM
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    [[ $# -eq 0 ]] || fail "usage: $0"
    run_mpp_qa
fi
