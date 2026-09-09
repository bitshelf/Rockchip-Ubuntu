#!/usr/bin/env bash
set -Eeuo pipefail
project="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/scripts" "$tmp/tests" "$tmp/config" "$tmp/package"
cp "$project/scripts/check-source.sh" "$tmp/scripts/"
cat >"$tmp/package/video.patch" <<'PATCH'
--- a/gpu/command_buffer/service/shared_image/factory.cc
+++ b/gpu/command_buffer/service/shared_image/factory.cc
@@ -1 +1 @@
-old();
+namespace video { }
PATCH
printf '# bash documentation\n}\n' >"$tmp/config/notes.txt"
printf '#!/usr/bin/env sh\nexit 99\n' >"$tmp/scripts/valid.sh"
bash "$tmp/scripts/check-source.sh" --syntax-only >"$tmp/result" 2>&1
printf '#!/bin/bash\nif then\n' >"$tmp/scripts/invalid.sh"
if bash "$tmp/scripts/check-source.sh" --syntax-only >"$tmp/result" 2>&1; then
    echo 'FAIL: invalid Bash script was accepted' >&2; exit 1
fi
printf '#!/usr/bin/env sh\nif then\n' >"$tmp/scripts/invalid.sh"
if bash "$tmp/scripts/check-source.sh" --syntax-only >"$tmp/result" 2>&1; then
    echo 'FAIL: invalid env sh script was accepted' >&2; exit 1
fi
echo 'Source syntax checks ignore patches and validate real Bash/sh scripts'
