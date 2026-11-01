#!/bin/sh
# GPUI owns the window; all content pixels come from the shared Zig renderer.
set -eu
repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"
if [ "$(uname -s)" != Darwin ]; then
    echo "The GPUI workspace packaging script currently supports macOS." >&2
    exit 1
fi
cargo build --locked --manifest-path apps/xy-gpui/Cargo.toml
out="$repo_root/build/xy-gpui/xy-gpui.app/Contents"
mkdir -p "$out/MacOS"
mkdir -p "$out/Resources/licenses"
cp apps/xy-gpui/target/debug/nihos-xy-gpui "$out/MacOS/.xy-gpui.new"
mv "$out/MacOS/.xy-gpui.new" "$out/MacOS/xy-gpui"
# The dedicated image is optional for shared-core snapshots. If present,
# bundle it so Finder launch does not depend on the shell's working directory.
rm -f "$out/Resources/nihos-native.elf" "$out/Resources/jisyo_s_nfst.bin"
if [ -f "$repo_root/build/xy-emulator-firmware/nihos-native.elf" ]; then
    cp "$repo_root/build/xy-emulator-firmware/nihos-native.elf" "$out/Resources/nihos-native.elf"
    if [ -f "$repo_root/src/xy/fixtures/jisyo_s_nfst.bin" ]; then
        cp "$repo_root/src/xy/fixtures/jisyo_s_nfst.bin" "$out/Resources/jisyo_s_nfst.bin"
    fi
fi
cp LICENSE "$out/Resources/licenses/nihos-MIT.txt"
cp src/xy/fonts/CC0.txt "$out/Resources/licenses/Bunsen-CC0.txt"
cp src/graphics/ascii/SourceCodePro-LICENSE.md "$out/Resources/licenses/SourceCodePro-OFL.txt"
cat > "$out/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>xy-gpui</string>
<key>CFBundleIdentifier</key><string>org.nihos.xy.gpui</string>
<key>CFBundleName</key><string>xy GPUI</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
printf '%s\n' "$repo_root/build/xy-gpui/xy-gpui.app"
