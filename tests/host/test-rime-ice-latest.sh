#!/usr/bin/env bash
set -Eeuo pipefail
# py_compile writes a cache even with PYTHONDONTWRITEBYTECODE=1. CI runs
# source checks as root, so syntax-check in memory and leave checkout writable.
python3 - <<'PY'
from pathlib import Path
script = Path('scripts/install-rime-ice.py')
compile(script.read_bytes(), str(script), 'exec')
PY
grep -Fq 'releases/latest/download/full.zip' scripts/install-rime-ice.py
grep -Fq '"--write-out", "%{url_effective}"' scripts/install-rime-ice.py
grep -Fq '"--max-time", "90"' scripts/install-rime-ice.py
grep -Fq 'sha256:' scripts/install-rime-ice.py
grep -Fq 'rime_ice.schema.yaml' scripts/install-rime-ice.py
test -s config/customization/fcitx5/profile
test -s config/customization/fcitx5/org.fcitx.Fcitx5.desktop
test -s config/customization/fcitx5/fcitx5.conf
bash -n scripts/install-fcitx5-customization.sh
python3 tests/host/test-rime-ice-download.py
grep -Fq 'install-rime-ice.py' scripts/install-fcitx5-customization.sh
grep -Fq 'RIME_ICE_ARCHIVE' scripts/install-fcitx5-customization.sh
grep -Fq 'RIME_ICE_RESOLVED_URL' scripts/build-overlay-root.sh
echo "Rime/Fcitx5 latest-source contract passed"
