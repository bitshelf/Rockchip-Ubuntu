#!/usr/bin/env bash
set -Eeuo pipefail
test -x tests/target/test-chromium-mpp.sh
bash -n tests/target/test-chromium-mpp.sh
python3 tests/host/test-chromium-patches.py
! grep -Fq 'chromium, channel: latest\/stable' scripts/build-server.sh
grep -Fq 'use_v4l2_codec = true' package/chromium/args.gn
grep -Fq 'chromium-runtime' config/local-debs/packages.conf
grep -Fq 'chromium-runtime' config/local-debs/install.conf
grep -Fq 'v4l2_fd_open' docs/patches/chromium/0001-v4l2-route-device-operations-through-libv4l-rkmpp.patch
! grep -Eq 'chromium_(126|132)\.|chromium-(126|132)' config/local-debs/packages.conf
grep -Fq 'CHROMIUM_MPP_REAL_VIDEO_OK' tests/target/test-chromium-mpp.sh
grep -Fq 'CHROMIUM_MPP_VIDEO' tests/target/test-chromium-mpp.sh
! grep -Fq 'videotestsrc' tests/target/test-chromium-mpp.sh
grep -Fq 'totalVideoFrames' tests/target/test-chromium-mpp.sh
grep -Fq 'chrome://media-internals' tests/target/test-chromium-mpp.sh
grep -Fq 'V4L2VideoDecoder' tests/target/test-chromium-mpp.sh
grep -Fq 'media-internals.png' tests/target/test-chromium-mpp.sh
echo "Chromium MPP QA contract passed"
