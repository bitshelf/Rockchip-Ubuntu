ARG BASE_IMAGE=ubuntu
ARG BASE_TAG=latest
FROM ${BASE_IMAGE}:${BASE_TAG}

ARG DEBIAN_FRONTEND=noninteractive
ARG TARGET_DEB_ARCH
ARG TARGET_GNU_TRIPLET
ARG NATIVE_APT_MIRROR
ARG TARGET_APT_MIRROR

COPY configure-apt.sh /usr/local/sbin/configure-cross-apt
COPY entrypoint.sh /usr/local/bin/cross-build-env

RUN chmod 0755 /usr/local/sbin/configure-cross-apt \
        /usr/local/bin/cross-build-env \
    && bootstrap_native_mirror="$(printf '%s' "${NATIVE_APT_MIRROR}" | sed 's#^https://#http://#')" \
    && bootstrap_target_mirror="$(printf '%s' "${TARGET_APT_MIRROR}" | sed 's#^https://#http://#')" \
    && TARGET_DEB_ARCH="${TARGET_DEB_ARCH}" \
       NATIVE_APT_MIRROR="$bootstrap_native_mirror" \
       TARGET_APT_MIRROR="$bootstrap_target_mirror" \
       /usr/local/sbin/configure-cross-apt \
    && apt-get update \
    && apt-get install --yes --no-install-recommends ca-certificates \
    && TARGET_DEB_ARCH="${TARGET_DEB_ARCH}" \
       NATIVE_APT_MIRROR="${NATIVE_APT_MIRROR}" \
       TARGET_APT_MIRROR="${TARGET_APT_MIRROR}" \
       /usr/local/sbin/configure-cross-apt \
    && native_arch="$(dpkg --print-architecture)" \
    && packages='build-essential ca-certificates ccache cmake file git make meson ninja-build pkg-config' \
    && if [ "$native_arch" != amd64 ] || [ "$TARGET_DEB_ARCH" != arm64 ]; then \
           echo "unsupported build pair: ${native_arch} -> ${TARGET_DEB_ARCH}" >&2; \
           exit 1; \
       fi \
    && packages="$packages crossbuild-essential-arm64 binutils-aarch64-linux-gnu dpkg-dev patch libc6-dev:arm64 libbz2-dev:arm64 libcurl4-openssl-dev:arm64" \
    && apt-get update \
    && apt-get install --yes --no-install-recommends $packages \
    && rm -rf /var/lib/apt/lists/*

ENV TARGET_DEB_ARCH=${TARGET_DEB_ARCH}
ENV TARGET_GNU_TRIPLET=${TARGET_GNU_TRIPLET}
ENV DEBIAN_FRONTEND=noninteractive

WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/cross-build-env"]
CMD ["--check"]
