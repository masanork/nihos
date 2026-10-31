#!/bin/sh
set -eu
repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"
zig_bin=${ZIG:-$(tools/bootstrap-zig.sh)}
out="$repo_root/build/xy-tab5-preview"
mkdir -p "$out"
case $(uname -s) in Darwin) ext=dylib ;; *) ext=so ;; esac
python3 tools/build-xy-reading-pack.py "$out/xy-reading.pack" > "$out/pack-build.json"
"$zig_bin" build-lib -dynamic -O ReleaseSafe -fPIC -femit-bin="$out/libxy_tab5.$ext" \
    --dep view_config --dep surface --dep viewport_layout --dep rotated_surface -Mroot=src/xy/preview_host.zig \
    -Msurface=src/graphics/surface.zig --dep view_config -Mviewport_layout=src/graphics/viewport_layout.zig \
    -Mview_config=src/xy/view_config.zig --dep surface -Mrotated_surface=src/graphics/rotated_surface.zig
printf '%s\n' "$out/libxy_tab5.$ext"
