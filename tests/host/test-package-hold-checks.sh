#!/usr/bin/env bash
set -Eeuo pipefail
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
python3 - "$PROJECT_DIR" <<'PY'
from pathlib import Path
import os
import subprocess
import sys
import tempfile
project = Path(sys.argv[1])
with tempfile.TemporaryDirectory() as directory:
    producer = Path(directory) / 'apt-mark'
    producer.write_text('''#!/bin/bash
printf '%s\\n' "$HOLD_FIXTURE"
sleep 0.1
for ((i=0; i<10000; i++)); do echo unrelated-package; done
exit "${HOLD_PRODUCER_EXIT:-0}"
''')
    producer.chmod(0o755)
    (Path(directory) / 'ldd').symlink_to(producer)
    for name, package, probe in [('test-rknpu.sh', 'rknn-models', 'apt-mark showhold |'),
                                ('test-rga.sh', 'librga2', 'apt-mark showhold |'),
                                ('test-gpu-headless-egl.sh', 'libmali-test', 'apt-mark showhold |'),
                                ('test-rknpu.sh', 'librknnrt.so => /library', 'ldd /usr/bin/rknn_common_test |')]:
        line = next(line for line in (project/'tests/target'/name).read_text().splitlines()
                    if probe in line).strip().split(' ||')[0]
        command = 'package='+repr(package)+'; '+line
        environment = os.environ | {'PATH': directory+':'+os.environ['PATH']}
        for fixture, producer_exit, expected in [(package, '0', True),
                                                ('missing-package', '0', False),
                                                (package, '7', False)]:
            result = subprocess.run(['bash', '-o', 'pipefail', '-c', command],
                env=environment | {'HOLD_FIXTURE': fixture, 'HOLD_PRODUCER_EXIT': producer_exit},
                capture_output=True)
            assert (result.returncode == 0) == expected, (name, fixture, producer_exit, result.stderr)
        print(name+': '+probe+' complete output consumed; missing matches and producer failures rejected')
PY
