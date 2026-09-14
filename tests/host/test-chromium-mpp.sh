#!/usr/bin/env bash
set -Eeuo pipefail
test -x tests/target/test-chromium-mpp.sh
bash -n tests/target/test-chromium-mpp.sh
grep -Fq 'chromium, channel: latest\/stable' scripts/build-server.sh
grep -Fq '{name: bare}' scripts/build-server.sh
grep -Fq '{name: core22}' scripts/build-server.sh
grep -Fq '{name: core24}' scripts/build-server.sh
for provider in gtk-common-themes gnome-46-2404 mesa-2404 cups; do
    grep -Fq "{name: $provider, channel: latest\\/stable}" scripts/build-server.sh
done
! grep -Eq 'chromium_(126|132)\.|chromium-(126|132)' config/local-debs/packages.conf
grep -Fq 'CHROMIUM_MPP_REAL_VIDEO_OK' tests/target/test-chromium-mpp.sh
grep -Fq 'chrome://media-internals' tests/target/test-chromium-mpp.sh
grep -Fq 'V4L2VideoDecoder' tests/target/test-chromium-mpp.sh
grep -Fq 'media-internals.png' tests/target/test-chromium-mpp.sh
echo "Chromium MPP QA contract passed"
