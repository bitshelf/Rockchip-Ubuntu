ARG CROSS_ENV_IMAGE=ubuntu-cross-arm64:latest
FROM ${CROSS_ENV_IMAGE}

ARG DEBIAN_FRONTEND=noninteractive
ARG SOURCE_PACKAGE

RUN test -n "${SOURCE_PACKAGE}" \
    && apt-get update \
    && apt-get install --yes --no-install-recommends \
        debhelper devscripts fakeroot libdistro-info-perl patch quilt \
        zlib1g:arm64 \
    && DEB_BUILD_PROFILES='cross nodoc nocheck' \
       apt-get build-dep --yes --host-architecture=arm64 "${SOURCE_PACKAGE}"

COPY --chmod=0755 entrypoint.sh /usr/local/bin/build-cross-deb-example

ENTRYPOINT ["/usr/local/bin/cross-build-env", "--", "/usr/local/bin/build-cross-deb-example"]
