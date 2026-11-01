#!/bin/sh
set -eu
root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
NIHOS_NATIVE_RUST_PROBE=1 sh "$root/tools/run-native-smoke.sh" integer 0
python3 - "$root/build/native-emulator/psram-0/emulator.log" <<'PY'
import re
import sys
from pathlib import Path
text = Path(sys.argv[1]).read_text(errors='replace')
records = re.findall(r'^NIHOS_NATIVE_RUST_APP result=([0-9a-fA-F]{8})\s*$', text, re.M)
if records != ['00000000']:
    raise SystemExit(f'Rust fixture result missing, failed, or repeated: {records!r}')
tasks = re.findall(r'^NIHOS_NATIVE_RUST_TASK ran=00000001 reaped=00000003\s*$', text, re.M)
if len(tasks) != 3:
    raise SystemExit(f'Rust task or reaping evidence missing: {len(tasks)} records')
print('Rust native app and task emulator fixtures: ok')
PY
