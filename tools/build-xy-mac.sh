#!/bin/sh
set -eu
repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"
zig_bin=${ZIG:-$(tools/bootstrap-zig.sh)}
out="$repo_root/build/xy-mac"
mkdir -p "$out"
python3 tools/xy_sicp.py --check
python3 tools/xy_learning_pack.py "$out/learning.pack"
ZIG="$zig_bin" tools/build-sqld-host.sh >/dev/null
cp build/sqld/libsqld.dylib "$out/"
"$zig_bin" build-lib -dynamic -O ReleaseSafe -fPIC -install_name @rpath/libxy_host.dylib -femit-bin="$out/libxy_host.dylib" \
    --dep view_config --dep surface --dep viewport_layout --dep pixel_transfer --dep rotated_surface -Mroot=src/xy/c_abi_host.zig \
    -Msurface=src/graphics/surface.zig --dep view_config -Mviewport_layout=src/graphics/viewport_layout.zig \
    -Mview_config=src/xy/view_config.zig -Mpixel_transfer=src/graphics/pixel_transfer.zig \
    --dep surface -Mrotated_surface=src/graphics/rotated_surface.zig
clang -std=c11 -Wall -Wextra -Werror -dynamiclib -I include \
    tools/xy_workspace_sqlite.c -lsqlite3 \
    -Wl,-install_name,@rpath/libxy_workspace.dylib -o "$out/libxy_workspace.dylib"
clang -fobjc-arc -Wall -Wextra -Werror -I include tools/xy_mac_host.m \
    -L "$out" -lxy_host -lxy_workspace -lsqld -lsqlite3 \
    -framework Cocoa -framework ImageIO -framework WebKit -Wl,-rpath,@executable_path -Wl,-rpath,@executable_path/../Frameworks -o "$out/xy-mac-host"
cp assets/xy/library.json assets/xy/sicp-learning.json "$out/"
mkdir -p "$out/fonts" "$out/figures"
cp docs/book/figures/generated/*.svg "$out/figures/"
cp assets/xy/fonts/* "$out/fonts/"
mkdir -p "$out/licenses"
cp third_party/xy-typography/GUST-FONT-LICENSE.txt third_party/xy-typography/LPPL-1.3c.txt third_party/xy-typography/MANIFEST-TeX-Gyre-Schola.txt src/graphics/serif/manifest.json "$out/licenses/"
cp LICENSE src/graphics/ascii/SourceCodePro-LICENSE.md third_party/xy-reading/NOTICE.md third_party/xy-reading/CC-BY-SA-4.0.txt "$out/licenses/"
app="$out/xy.app/Contents"
mkdir -p "$app/MacOS" "$app/Frameworks" "$app/Resources"
cp assets/xy/library.json assets/xy/sicp-learning.json "$out/learning.pack" "$app/Resources/"
mkdir -p "$app/Resources/fonts" "$app/Resources/figures"
cp docs/book/figures/generated/*.svg "$app/Resources/figures/"
cp assets/xy/fonts/* "$app/Resources/fonts/"
mkdir -p "$app/Resources/licenses"
cp "$out/licenses/"* "$app/Resources/licenses/"
cp "$out/xy-mac-host" "$app/MacOS/xy-mac-host"
cp "$out/libxy_host.dylib" "$out/libxy_workspace.dylib" "$app/Frameworks/"
cp "$out/libsqld.dylib" "$app/Frameworks/"
cat > "$app/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>xy-mac-host</string>
<key>CFBundleIdentifier</key><string>org.nihos.xy.pixelhost</string>
<key>CFBundleName</key><string>xy</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
printf '%s\n' "$out/xy.app"
