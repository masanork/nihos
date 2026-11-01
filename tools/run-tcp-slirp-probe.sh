#!/bin/sh
# Host-only test; requires external libslirp headers/library and Zig.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
: "${SLIRP_PREFIX:?set SLIRP_PREFIX to a libslirp installation}"
ZIG=${ZIG:-"$ROOT/.tools/zig-0.17.0/zig"}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/nihos-tcp-slirp.XXXXXX")
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
case "$(uname -s)" in
    Darwin) EXT=dylib ;;
    *) EXT=so ;;
esac
cd "$ROOT"
"$ZIG" build-lib -dynamic -O ReleaseSafe "-femit-bin=$WORK/libtcp_probe.$EXT" src/net/tcp_host_probe.zig
${CC:-cc} -Wall -Wextra -Werror -Wno-deprecated-declarations -I"$SLIRP_PREFIX/include" \
    tools/tcp_slirp_probe.c "$SLIRP_PREFIX/lib/libslirp.$EXT" "$WORK/libtcp_probe.$EXT" \
    -Wl,-rpath,"$SLIRP_PREFIX/lib" -Wl,-rpath,"$WORK" -o "$WORK/tcp_slirp_probe"
"$WORK/tcp_slirp_probe"
