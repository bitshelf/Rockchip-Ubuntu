#!/usr/bin/env bash
set -Eeuo pipefail

destination="${1:-debian/tmp}"
sdk_dir="${SDK_DIR:?SDK_DIR must point to the Rockchip SDK root}"
runtime="${sdk_dir}/external/rknpu2/runtime/Linux"
archive="${sdk_dir}/debian/packages/arm64/rknpu2/rknpu2.tar"
extract_dir="$(mktemp -d)"
trap 'rm -rf -- "$extract_dir"' EXIT

for source in \
    "$runtime/librknn_api/aarch64/librknnrt.so" \
    "$runtime/rknn_server/aarch64/usr/bin/rknn_server" \
    "$runtime/librknn_api/include/rknn_api.h" \
    "$runtime/librknn_api/include/rknn_custom_op.h" \
    "$runtime/librknn_api/include/rknn_matmul_api.h" \
    "$archive"; do
    [[ -s "$source" && ! -L "$source" ]] || {
        echo "ERROR: missing RKNPU2 SDK input: $source" >&2
        exit 1
    }
done

tar -xf "$archive" -C "$extract_dir"
install -d -m 0755 \
    "$destination/usr/bin" \
    "$destination/usr/include" \
    "$destination/usr/lib" \
    "$destination/usr/lib/aarch64-linux-gnu" \
    "$destination/usr/lib/aarch64-linux-gnu/cmake" \
    "$destination/usr/lib/aarch64-linux-gnu/pkgconfig" \
    "$destination/usr/lib/udev/rules.d" \
    "$destination/usr/share/model"

install -m 0755 "$runtime/librknn_api/aarch64/librknnrt.so" \
    "$destination/usr/lib/aarch64-linux-gnu/librknnrt.so"
ln -s aarch64-linux-gnu/librknnrt.so "$destination/usr/lib/librknnrt.so"
install -m 0755 "$runtime/rknn_server/aarch64/usr/bin/rknn_server" \
    "$destination/usr/bin/rknn_server"
install -m 0755 "$extract_dir/usr/bin/rknn_common_test" \
    "$destination/usr/bin/rknn_common_test"
install -m 0644 "$runtime/librknn_api/include/"*.h "$destination/usr/include/"
install -m 0644 debian/rknn_api.pc \
    "$destination/usr/lib/aarch64-linux-gnu/pkgconfig/rknn_api.pc"
install -m 0644 debian/RKNN.cmake \
    "$destination/usr/lib/aarch64-linux-gnu/cmake/RKNN.cmake"
install -m 0644 debian/60-rockchip-rknpu.rules \
    "$destination/usr/lib/udev/rules.d/60-rockchip-rknpu.rules"
install -m 0644 "$extract_dir/usr/share/model/"*.jpg \
    "$destination/usr/share/model/"

while IFS= read -r -d '' model; do
    model_directory="$(basename "$(dirname "$model")")"
    [[ "$model_directory" =~ ^[A-Za-z0-9_+-]+$ ]] || {
        echo "ERROR: unsafe RKNPU2 model directory: $model_directory" >&2
        exit 1
    }
    install -D -m 0644 "$model" \
        "$destination/usr/share/model/$model_directory/mobilenet_v1.rknn"
done < <(find "$extract_dir/usr/share/model" -mindepth 2 -maxdepth 2 \
    -type f -name mobilenet_v1.rknn -print0 | sort -z)

find "$destination/usr/share/model" -mindepth 2 -maxdepth 2 \
    -type f -name mobilenet_v1.rknn -print -quit | grep -q . || {
        echo "ERROR: RKNPU2 archive contains no MobileNet model" >&2
        exit 1
    }
