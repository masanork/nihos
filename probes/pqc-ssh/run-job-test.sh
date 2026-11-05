#!/bin/sh
# Host-only KEM job ownership and C/Zig interoperability.
set -eu
: "${ZIG:?set ZIG to Zig 0.17.0}"
: "${NIHOS_MLKEM_ARCHIVE:?set NIHOS_MLKEM_ARCHIVE to pinned source tarball}"
root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$root"
[ "$($ZIG version)" = 0.17.0 ]
out="$root/build/pqc-ssh-rv32"
# Verify the archive and restore its source files before compiling.
sh probes/pqc-ssh/rv32-study.sh >/dev/null
kem="$out/mlkem-native-e0e0ae95765f4c48585dc8cdaa0656d4eda46a06/mlkem"
for name in mlkem arena job; do
    case "$name" in
        mlkem) src="$kem/mlkem_native.c" ;;
        arena) src=probes/pqc-ssh/mlkem_arena.c ;;
        job) src=probes/pqc-ssh/kem_job.c ;;
    esac
    set --
    if [ "$name" = job ]; then set -- -DNIH_KEM_TEST_FAILURE; fi
    "$ZIG" cc -O2 -std=c11 -DMLK_CONFIG_PARAMETER_SET=768 -DMLK_CONFIG_NO_RANDOMIZED_API "$@" \
      -include probes/pqc-ssh/mlkem_arena.h -I "$kem" -c "$src" -o "$out/host-$name.o"
done
"$ZIG" test probes/pqc-ssh/kem_job_test.zig "$out/host-mlkem.o" "$out/host-arena.o" "$out/host-job.o" -lc -O ReleaseSafe
