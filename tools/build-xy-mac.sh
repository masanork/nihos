#!/bin/sh
# Reproducible shared-core Cocoa development host (fonts remain paged inputs).
set -eu
repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
zig=$(sh "$repo_root/tools/bootstrap-zig.sh")
cd "$repo_root"
mkdir -p build/xy-mac
"$zig" build-lib -dynamic -O safe \
    --dep view_config --dep surface --dep viewport_layout -Mroot=src/xy/c_abi_host.zig \
    -O safe --dep view_config -Mviewport_layout=src/graphics/viewport_layout.zig \
    -O safe -Mview_config=src/xy/view_config.zig \
    -O safe -Msurface=src/graphics/surface.zig \
    -femit-bin=build/xy-mac/libxy_host.dylib
clang -O2 -framework Cocoa -framework ImageIO tools/xy_mac_host.m \
    -Lbuild/xy-mac -lxy_host -lsqlite3 -Wl,-rpath,@executable_path -o build/xy-mac/xy_mac_host
