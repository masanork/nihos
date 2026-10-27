#!/bin/sh
set -eu

version=1.7.4
sha256=936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88
repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
install_dir="$repo_root/.tools/tlc-$version"
jar="$install_dir/tla2tools.jar"

if [ ! -f "$jar" ]; then
    mkdir -p "$install_dir"
    stage=$(mktemp -d "$install_dir/download.XXXXXX")
    trap 'rm -rf "$stage"' EXIT HUP INT TERM
    curl -fsSL "https://github.com/tlaplus/tlaplus/releases/download/v$version/tla2tools.jar" \
        -o "$stage/tla2tools.jar"
    # Verify before publishing a downloaded artifact, and on every cache hit.
    python3 - "$stage/tla2tools.jar" "$sha256" <<'PY'
import hashlib
import pathlib
import sys

if hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest() != sys.argv[2]:
    raise SystemExit("TLC archive checksum mismatch")
PY
    mv "$stage/tla2tools.jar" "$jar"
fi

python3 - "$jar" "$sha256" <<'PY'
import hashlib
import pathlib
import sys

if hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest() != sys.argv[2]:
    raise SystemExit("TLC archive checksum mismatch")
PY
echo "$jar"
