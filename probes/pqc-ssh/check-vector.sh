#!/bin/sh
# Independently regenerate the public fixture from Zig's ML-KEM and Ed25519.
set -eu
: "${ZIG:?set ZIG to Zig 0.17.0}"
root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$root"
[ "$($ZIG version)" = 0.17.0 ]
mkdir -p build/pqc-ssh-vector
case "$(uname -s)" in Darwin) ext=dylib ;; *) ext=so ;; esac
"$ZIG" build-lib -dynamic -O ReleaseSafe -femit-bin="$root/build/pqc-ssh-vector/generator.$ext" src/net/ssh_hybrid_vector_gen.zig
python3 - "$root/build/pqc-ssh-vector/generator.$ext" <<'PY'
import ctypes, hashlib, sys
from pathlib import Path
lib=ctypes.CDLL(sys.argv[1])
lib.nih_make_public_ssh_vector.argtypes=[ctypes.c_void_p]
lib.nih_make_public_ssh_vector.restype=ctypes.c_bool
buf=ctypes.create_string_buffer(2630)
if not lib.nih_make_public_ssh_vector(buf): raise SystemExit('vector generation failed')
expected=Path('src/net/ssh_hybrid_public_vector.bin').read_bytes()
if buf.raw != expected: raise SystemExit('public fixture differs from reference generation')
print('public fixture matches Zig reference:',hashlib.sha256(expected).hexdigest())
PY
