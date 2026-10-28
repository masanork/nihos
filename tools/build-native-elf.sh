#!/bin/sh
# No ESP-IDF installation is needed to compile/link the native application.
set -eu
repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
profile=${1:-device}
case "$profile" in
    device) rev3=0 ;;
    emulator) rev3=1 ;;
    *) echo "usage: $0 [device|emulator] [output-directory] [integer|floating|compiled|sqlite]" >&2; exit 1 ;;
esac
build_dir=${2:-"$repo_root/build/native-$profile"}
network=${NIHOS_NATIVE_NETWORK:-0}
case "$network" in 0) network=false; network_cpp=0 ;; 1) network=true; network_cpp=1; umask 077 ;; *) echo "NETWORK must be 0 or 1" >&2; exit 1 ;; esac
if [ "$network" = true ] && [ "$#" -lt 2 ]; then build_dir="$build_dir-network"; fi
network_test=${NIHOS_NATIVE_NETWORK_TEST:-0}
case "$network_test" in 0) network_test=false ;; 1) network_test=true ;; *) echo "NETWORK_TEST must be 0 or 1" >&2; exit 1 ;; esac
if [ "$network_test" = true ] && [ "$network" != true ]; then echo "NETWORK_TEST requires NETWORK=1" >&2; exit 1; fi
devices=${NIHOS_NATIVE_DEVICES:-0}
case "$devices" in 0) devices=false; devices_cpp=0 ;; 1) devices=true; devices_cpp=1 ;; *) echo "DEVICES must be 0 or 1" >&2; exit 1 ;; esac
audio=${NIHOS_NATIVE_AUDIO:-0}
case "$audio" in 0) audio=false ;; 1) audio=true ;; *) echo "AUDIO must be 0 or 1" >&2; exit 1 ;; esac
microphone=${NIHOS_NATIVE_MICROPHONE:-0}
case "$microphone" in 0) microphone=false ;; 1) microphone=true ;; *) echo "MICROPHONE must be 0 or 1" >&2; exit 1 ;; esac
if [ "$audio" = true ] && [ "$microphone" = true ]; then echo "AUDIO and MICROPHONE share I2S0 and cannot run together" >&2; exit 1; fi
microphone_muted=${NIHOS_NATIVE_MICROPHONE_MUTED:-0}
case "$microphone_muted" in 0) microphone_muted=false ;; 1) microphone_muted=true ;; *) echo "MICROPHONE_MUTED must be 0 or 1" >&2; exit 1 ;; esac
if [ "$microphone_muted" = true ] && [ "$microphone" != true ]; then echo "MICROPHONE_MUTED requires MICROPHONE=1" >&2; exit 1; fi
rs485=${NIHOS_NATIVE_RS485:-0}
case "$rs485" in 0) rs485=false ;; 1) rs485=true ;; *) echo "RS485 must be 0 or 1" >&2; exit 1 ;; esac
rs485_test=${NIHOS_NATIVE_RS485_TEST:-loopback}
case "$rs485_test" in loopback) rs485_mode=1 ;; peer) rs485_mode=2 ;; no-loopback) rs485_mode=3 ;; *) echo "RS485_TEST must be loopback, peer or no-loopback" >&2; exit 1 ;; esac
if [ "$rs485" != true ] && [ "$rs485_test" != loopback ]; then echo "RS485_TEST requires RS485=1" >&2; exit 1; fi
if [ "$rs485" = true ] && { [ "$audio" = true ] || [ "$microphone" = true ]; }; then echo "RS485 fixture uses a separate build from audio/microphone fixtures" >&2; exit 1; fi
if [ "$devices" = true ] && { [ "$audio" = true ] || [ "$microphone" = true ] || [ "$rs485" = true ]; }; then echo "DEVICES uses on-demand requests; select one standalone fixture instead" >&2; exit 1; fi
root_opt=safe
if [ "$network" = true ] || [ "$devices" = true ]; then root_opt=small; fi
mode=${3:-integer}
if [ "$profile" = device ]; then default_cpu_mhz=360; else default_cpu_mhz=0; fi
cpu_mhz=${NIHOS_NATIVE_CPU_MHZ:-$default_cpu_mhz}
case "$cpu_mhz" in
    0|360) ;;
    *) echo "Native rev1/2 supports CPU_MHZ=0 or 360; 400 MHz is not this silicon's standard profile" >&2; exit 1 ;;
esac
if [ "$profile" = emulator ] && [ "$cpu_mhz" != 0 ]; then echo "CPU clock initialization requires physical device" >&2; exit 1; fi
cpu=generic_rv32+m+a+c+zicsr+zifencei
compiled=false
sqlite=false
sqlite_cpp=0
graphics=false
graphics_cpp=0
abi=ilp32
qualification=${NIHOS_NATIVE_QUALIFICATION:-0}
case "$qualification" in
    0) qualification=false ;;
    1) qualification=true ;;
    *) echo "NIHOS_NATIVE_QUALIFICATION must be 0 or 1" >&2; exit 1 ;;
esac
case "$mode" in
    integer) floating=false; fp_asm=0 ;;
    sqlite) floating=false; fp_asm=0; sqlite=true; sqlite_cpp=1 ;;
    graphics) floating=false; fp_asm=0; graphics=true; graphics_cpp=1 ;;
    floating) floating=true; fp_asm=1 ;;
    compiled) floating=true; fp_asm=1; compiled=true; cpu=generic_rv32+m+a+c+f+zicsr+zifencei; abi=ilp32f ;;
    *) echo "mode must be integer, floating, compiled, sqlite or graphics" >&2; exit 1 ;;
esac
usb=${NIHOS_NATIVE_USB:-0}
case "$usb" in
    0) usb=false ;;
    1) usb=true ;;
    *) echo "NIHOS_NATIVE_USB must be 0 or 1" >&2; exit 1 ;;
esac
if [ "$usb" = true ] && [ "$profile" != device ]; then
    echo "Native USB probe currently supports the rev1/2 device profile only" >&2
    exit 1
fi
jpki=${NIHOS_NATIVE_JPKI:-0}
case "$jpki" in
    0) jpki=false ;;
    1) jpki=true ;;
    *) echo "NIHOS_NATIVE_JPKI must be 0 or 1" >&2; exit 1 ;;
esac
if [ "$jpki" = true ] && [ "$usb" != true ]; then
    echo "PIN-free JPKI requires NIHOS_NATIVE_USB=1" >&2
    exit 1
fi
sdmmc=${NIHOS_NATIVE_SDMMC:-0}
case "$sdmmc" in
    0) sdmmc=false ;;
    1) sdmmc=true ;;
    *) echo "NIHOS_NATIVE_SDMMC must be 0 or 1" >&2; exit 1 ;;
esac
sdmmc_profile=${NIHOS_NATIVE_SDMMC_PROFILE:-0}
case "$sdmmc_profile" in
    0|1|2) ;;
    *) echo "NIHOS_NATIVE_SDMMC_PROFILE must be 0, 1 or 2" >&2; exit 1 ;;
esac
if [ "$sdmmc_profile" != 0 ] && [ "$sdmmc" != true ]; then
    echo "SDMMC profiles require NIHOS_NATIVE_SDMMC=1" >&2
    exit 1
fi
storage=${NIHOS_NATIVE_STORAGE:-0}
psram_200=${NIHOS_NATIVE_PSRAM_200:-0}
case "$psram_200" in
    0) psram_200=false ;;
    1) psram_200=true ;;
    *) echo "NIHOS_NATIVE_PSRAM_200 must be 0 or 1" >&2; exit 1 ;;
esac
psram_mpll=${NIHOS_NATIVE_PSRAM_MPLL:-0}
if [ "$psram_200" = true ]; then psram_mpll=1; fi
case "$psram_mpll" in
    0) psram_mpll=false ;;
    1) psram_mpll=true ;;
    *) echo "NIHOS_NATIVE_PSRAM_MPLL must be 0 or 1" >&2; exit 1 ;;
esac
if [ "$psram_mpll" = true ] && [ "$profile" != device ]; then
    echo "MPLL probe requires physical device" >&2
    exit 1
fi
display_hz=${NIHOS_NATIVE_DISPLAY_HZ:-60}
case "$display_hz" in
    60|65) ;;
    *) echo "NIHOS_NATIVE_DISPLAY_HZ must be 60 or 65" >&2; exit 1 ;;
esac
display=${NIHOS_NATIVE_DISPLAY:-0}
display_scanout=false
display_white=false
display_pattern=false
display_sram=false
display_tile=false
display_scene=false
display_tile_cpp=0
keypad_demo=false
card_read=false
card_photo=false
card_auto=false
photo_cpp=0
card_read_cpp=0
keypad_cpp=0
display_boot_cpp=0
case "$display" in
    0) display=false ;;
    1) display=true ;;
    2) display=true; display_scanout=true ;;
    3) display=true; display_scanout=true; display_white=true ;;
    4) display=true; display_scanout=true; display_white=true; display_pattern=true ;;
    5) display=true; display_scanout=true; display_white=true; display_sram=true ;;
    6) display=true; display_scanout=true; display_sram=true; display_tile=true ;;
    7) display=true; display_scanout=true; display_sram=true; display_tile=true; display_scene=true ;;
    11) display=true; display_scanout=true; display_sram=true; card_read=true; card_photo=true; card_auto=true; photo_cpp=1; card_read_cpp=1; keypad_cpp=1 ;;
    10) display=true; display_scanout=true; display_sram=true; card_read=true; card_photo=true; photo_cpp=1; card_read_cpp=1; keypad_cpp=1 ;;
    9) display=true; display_scanout=true; display_sram=true; card_read=true; card_read_cpp=1; keypad_cpp=1 ;;
    8) display=true; display_scanout=true; display_sram=true; keypad_demo=true; keypad_cpp=1 ;;
    *) echo "NIHOS_NATIVE_DISPLAY must be 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 or 11" >&2; exit 1 ;;
esac
console_font=${NIHOS_NATIVE_CONSOLE_FONT:-3}
case "$console_font" in
    0|1|2|3) ;;
    *) echo "NIHOS_NATIVE_CONSOLE_FONT must be 0, 1, 2 or 3" >&2; exit 1 ;;
esac
console_palette=${NIHOS_NATIVE_CONSOLE_PALETTE:-4}
case "$console_palette" in
    0|1|2|3|4) ;;
    *) echo "NIHOS_NATIVE_CONSOLE_PALETTE must be 0, 1, 2, 3 or 4" >&2; exit 1 ;;
esac
console=${NIHOS_NATIVE_CONSOLE:-0}
case "$console" in
    0) console=false ;;
    1) console=true ;;
    *) echo "NIHOS_NATIVE_CONSOLE must be 0 or 1" >&2; exit 1 ;;
esac
if [ "$console" = true ] && { [ "${NIHOS_NATIVE_DISPLAY:-0}" != 2 ] || [ "$psram_200" != true ]; }; then
    echo "Native console requires DISPLAY=2 and PSRAM_200=1" >&2
    exit 1
fi
console_fault=${NIHOS_NATIVE_CONSOLE_FAULT:-0}
case "$console_fault" in 0) console_fault=false ;; 1) console_fault=true ;; *) echo "CONSOLE_FAULT must be 0 or 1" >&2; exit 1 ;; esac
console_live=${NIHOS_NATIVE_CONSOLE_LIVE:-0}
keyboard_i2c=${NIHOS_NATIVE_KEYBOARD_I2C:-0}
case "$console_live" in 0) console_live=false ;; 1) console_live=true ;; *) echo "CONSOLE_LIVE must be 0 or 1" >&2; exit 1 ;; esac
case "$keyboard_i2c" in 0) keyboard_i2c=false ;; 1) keyboard_i2c=true ;; *) echo "KEYBOARD_I2C must be 0 or 1" >&2; exit 1 ;; esac
if [ "$console_live" = true ] && [ "$console" != true ]; then echo "Live UI requires CONSOLE=1" >&2; exit 1; fi
if [ "$console_fault" = true ] && [ "$console_live" != true ]; then echo "Fault fixture requires CONSOLE_LIVE=1" >&2; exit 1; fi
if [ "$keyboard_i2c" = true ] && [ "$console_live" != true ]; then echo "Keyboard requires CONSOLE_LIVE=1" >&2; exit 1; fi
# Headless normal-boot execution/fault cases are emulator-only, never a device
# workaround for missing LCD/PSRAM200 evidence. 0=off, 1=normal, 2=late CPU1,
# 3=missing ready, 4=missing IPI reply, 5=missing CPU1 timer.
boot_test=${NIHOS_NATIVE_BOOT_TEST:-0}
case "$boot_test" in 0|1|2|3|4|5) ;; *) echo "NIHOS_NATIVE_BOOT_TEST must be 0..5" >&2; exit 1 ;; esac
if [ "$boot_test" != 0 ] && { [ "$profile" != emulator ] || [ "$mode" != integer ] || [ "$qualification" != false ] || [ "$console_live" != false ] || [ "$display" != false ] || [ "$sdmmc" != false ]; }; then
    echo "Boot test requires headless emulator integer profile, without qualification/SDMMC" >&2; exit 1
fi
# Interactive integer console boots normally; other profiles remain fixtures.
boot_fast=${NIHOS_NATIVE_BOOT_FAST:-auto}
if [ "$boot_fast" = auto ]; then
    if { [ "$console_live" = true ] || [ "$boot_test" != 0 ]; } && [ "$mode" = integer ] && [ "$qualification" = false ]; then boot_fast=1; else boot_fast=0; fi
fi
case "$boot_fast" in
    0) boot_fast=false ;;
    1) boot_fast=true ;;
    *) echo "NIHOS_NATIVE_BOOT_FAST must be auto, 0 or 1" >&2; exit 1 ;;
esac
if [ "$boot_test" != 0 ] && [ "$boot_fast" != true ]; then echo "Boot test requires normal boot" >&2; exit 1; fi
if [ "$boot_fast" = true ] && { { [ "$console_live" != true ] && [ "$boot_test" = 0 ]; } || [ "$mode" != integer ] || [ "$qualification" = true ]; }; then
    echo "Normal boot requires live integer console and QUALIFICATION=0" >&2; exit 1
fi
if [ "$network" = true ] && { [ "$profile" != device ] || [ "$boot_fast" != true ] || [ "$sdmmc" != false ]; }; then
    echo "NETWORK requires normal device boot and exclusive SDMMC (SDMMC=0)" >&2; exit 1
fi
auto_probe=${NIHOS_NATIVE_CARD_AUTO_PROBE:-0}
case "$auto_probe" in
    0) auto_probe=false ;;
    1) auto_probe=true ;;
    *) echo "NIHOS_NATIVE_CARD_AUTO_PROBE must be 0 or 1" >&2; exit 1 ;;
esac
if [ "$auto_probe" = true ] && [ "$card_auto" != true ]; then
    echo "Automatic card probe requires DISPLAY=11" >&2; exit 1
fi
scene_exercise=${NIHOS_NATIVE_CARD_SCENE_EXERCISE:-0}
case "$scene_exercise" in
    0) scene_exercise=false ;;
    1) scene_exercise=true ;;
    *) echo "NIHOS_NATIVE_CARD_SCENE_EXERCISE must be 0 or 1" >&2; exit 1 ;;
esac
if [ "$scene_exercise" = true ] && { [ "$card_auto" != true ] || [ "$auto_probe" != true ]; }; then
    echo "Card scene exercise requires DISPLAY=11 and CARD_AUTO_PROBE=1; no card operations" >&2; exit 1
fi
if [ "$display_scanout" = true ]; then display_boot_cpp=1; fi
if [ "$display_tile" = true ]; then display_tile_cpp=1; fi
if [ "$display" = true ] && [ "$profile" != device ]; then
    echo "Native display preparation requires the physical-device profile" >&2
    exit 1
fi
card_check=${NIHOS_NATIVE_CARD_CHECK:-0}
if [ "$keypad_demo" = true ] && { [ "$usb" = true ] || [ "$jpki" = true ] || [ "$card_check" != 0 ]; }; then
    echo "Keypad demonstration requires USB=0, JPKI=0 and CARD_CHECK=0" >&2
    exit 1
fi
if [ "$keypad_demo" = true ] && [ "$mode" != integer ]; then
    echo "Keypad demonstration requires integer mode" >&2
    exit 1
fi
if [ "$card_read" = true ] && { [ "$usb" != true ] || [ "$jpki" = true ] || [ "$card_check" != 0 ] || [ "$mode" != integer ] || [ "$sdmmc" = true ] || [ "$storage" != 0 ]; }; then
    echo "Card read requires USB=1, JPKI=0, CARD_CHECK=0, SDMMC=0, STORAGE=0 and integer mode" >&2
    exit 1
fi
touch_check=${NIHOS_NATIVE_TOUCH_CHECK:-0}
case "$touch_check" in
    0) touch_check=false ;;
    1) touch_check=true ;;
    *) echo "NIHOS_NATIVE_TOUCH_CHECK must be 0 or 1" >&2; exit 1 ;;
esac
if [ "$touch_check" = true ] && { [ "$display_tile" != true ] || [ "$usb" = true ] || [ "$jpki" = true ] || [ "$card_check" != 0 ]; }; then
    echo "Touch feedback requires DISPLAY=6, USB=0, JPKI=0 and CARD_CHECK=0" >&2
    exit 1
fi
case "$card_check" in
    0) card_check=false ;;
    1) card_check=true ;;
    *) echo "NIHOS_NATIVE_CARD_CHECK must be 0 or 1" >&2; exit 1 ;;
esac
if [ "$card_check" = true ] && { [ "$usb" != true ] || [ "$display" != true ] || [ "$display_scanout" = true ]; }; then
    echo "Card readiness check requires USB=1 and DISPLAY=1 (preparation only)" >&2
    exit 1
fi
# Keep foreground-only PIN-free readiness/touch fixtures within the same 48 KiB
# heap gate as normal networking. The card/CCID modules remain ReleaseSafe;
# only the native orchestration/transport root uses the smaller codegen.
if [ "$card_check" = true ] || [ "$touch_check" = true ]; then root_opt=small; fi
case "$storage" in
    0) storage=false ;;
    1) storage=true ;;
    *) echo "NIHOS_NATIVE_STORAGE must be 0 or 1" >&2; exit 1 ;;
esac
if [ "$storage" = true ] && { [ "$sdmmc" != true ] || [ "$sqlite" != true ]; }; then
    echo "Storage probe requires SDMMC=1 and sqlite mode (shared audited Flash span)" >&2
    exit 1
fi
zig="$repo_root/.tools/zig-0.17.0/zig"
if [ ! -x "$zig" ]; then sh "$repo_root/tools/bootstrap-zig.sh" >/dev/null; fi
if [ "$devices" = true ] && { [ "$profile" != device ] || [ "$mode" != integer ] || [ "$console_live" != true ] || [ "$boot_fast" != true ] || [ "${NIHOS_NATIVE_DISPLAY:-0}" != 2 ] || [ "$psram_200" != true ] || [ "$boot_test" != 0 ] || [ "$sdmmc" = true ]; }; then
    echo "DEVICES requires the normal integer live-console device profile" >&2; exit 1
fi
if [ "$audio" = true ] && { [ "$profile" != device ] || [ "$mode" != integer ] || [ "$console_live" != true ] || [ "$boot_fast" != true ]; }; then
    echo "AUDIO requires the normal native integer device display/console boot" >&2; exit 1
fi
if [ "$microphone" = true ] && { [ "$profile" != device ] || [ "$mode" != integer ] || [ "$console_live" != true ] || [ "$boot_fast" != true ]; }; then
    echo "MICROPHONE requires the normal native integer device display/console boot" >&2; exit 1
fi
if [ "$rs485" = true ] && { [ "$profile" != device ] || [ "$mode" != integer ] || [ "$console_live" != true ] || [ "$boot_fast" != true ]; }; then
    echo "RS485 requires the normal native integer device display/console boot" >&2; exit 1
fi
if [ "$graphics" = true ] && { [ "$display" = true ] || [ "$console" = true ] || [ "$network" = true ] || [ "$devices" = true ] || [ "$audio" = true ] || [ "$microphone" = true ] || [ "$rs485" = true ] || [ "$usb" = true ] || [ "$sdmmc" = true ]; }; then
    echo "GRAPHICS is an isolated offscreen qualification profile; display/device/network/storage combinations are unsupported" >&2; exit 1
fi
mkdir -p "$build_dir"
native_boot_dir="$repo_root/build/native-$profile"
if [ "$network" = true ]; then native_boot_dir="$native_boot_dir-network"; fi
if [ "$audio" = true ]; then native_boot_dir="$native_boot_dir-audio"; fi
if [ "$microphone" = true ]; then native_boot_dir="$native_boot_dir-microphone"; fi
if [ "$rs485" = true ]; then native_boot_dir="$native_boot_dir-rs485"; fi
if [ "$devices" = true ]; then native_boot_dir="$native_boot_dir-devices"; fi
network_json=
if [ "$network" = true ]; then network_json=${NIHOS_C6_WIFI_CONFIG:-}; fi
NIHOS_C6_IPV6=1 python3 "$repo_root/tools/c6-wifi-config.py" "$build_dir/network-config.zig" "$network_json" hosted >/dev/null
"$zig" cc -E -P -x c -DNIH_NATIVE_NETWORK="$network_cpp" -DNIH_NATIVE_DEVICES="$devices_cpp" -DNIH_NATIVE_REV3="$rev3" -DNIH_NATIVE_SQLITE="$sqlite_cpp" -DNIH_NATIVE_KEYPAD="$keypad_cpp" -DNIH_NATIVE_CARD_READ="$card_read_cpp" -DNIH_NATIVE_PHOTO="$photo_cpp" -DNIH_NATIVE_GRAPHICS="$graphics_cpp" \
    "$repo_root/src/platform/native/esp32p4.ld" -o "$build_dir/native-layout.ld"
printf 'pub const floating = %s;\npub const compiled = %s;\npub const sqlite = %s;\npub const qualification = %s;\npub const sdmmc = %s;\npub const sdmmc_profile: u32 = %s;\npub const storage = %s;\npub const display = %s;\npub const display_scanout = %s;\npub const display_white = %s;\npub const display_pattern = %s;\npub const display_sram = %s;\npub const display_tile = %s;\npub const display_scene = %s;\npub const psram_mpll = %s;\npub const psram_200 = %s;\npub const display_hz: u32 = %s;\npub const console = %s;\npub const console_palette: u32 = %s;\npub const console_font: u32 = %s;\npub const console_live = %s;\npub const keyboard_i2c = %s;\npub const console_fault = %s;\n' "$floating" "$compiled" "$sqlite" "$qualification" "$sdmmc" "$sdmmc_profile" "$storage" "$display" "$display_scanout" "$display_white" "$display_pattern" "$display_sram" "$display_tile" "$display_scene" "$psram_mpll" "$psram_200" "$display_hz" "$console" "$console_palette" "$console_font" "$console_live" "$keyboard_i2c" "$console_fault" > "$build_dir/native_options.next"
{
    printf 'pub const boot_test: u32 = %s;\n' "$boot_test"
    printf 'pub const boot_fast = %s;\n' "$boot_fast"
    printf 'pub const cpu_mhz: u32 = %s;\n' "$cpu_mhz"
    printf 'pub const devices = %s;\n' "$devices"
    printf 'pub const audio = %s;\n' "$audio"
    printf 'pub const rs485 = %s;\n' "$rs485"
    printf 'pub const rs485_mode: u32 = %s;\n' "$rs485_mode"
    printf 'pub const microphone = %s;\n' "$microphone"
    printf 'pub const microphone_muted = %s;\n' "$microphone_muted"
    printf 'pub const network = %s;\n' "$network"
    printf 'pub const network_test = %s;\n' "$network_test"
    printf 'pub const card_check = %s;\n' "$card_check"
    printf 'pub const touch_check = %s;\n' "$touch_check"
    printf 'pub const keypad_demo = %s;\npub const card_read = %s;\npub const card_photo = %s;\n' "$keypad_demo" "$card_read" "$card_photo"
    printf 'pub const card_auto = %s;\npub const card_auto_probe = %s;\n' "$card_auto" "$auto_probe"
    printf 'pub const card_scene_exercise = %s;\n' "$scene_exercise"
    printf 'pub const usb = %s;\npub const jpki = %s;\n' "$usb" "$jpki"
    printf 'pub const graphics = %s;\n' "$graphics"
    if [ "$graphics" = true ]; then python3 "$repo_root/probes/graphics/generate_text_cases.py" --zig; fi
} >> "$build_dir/native_options.next"
if cmp -s "$build_dir/native_options.next" "$build_dir/native_options.zig"; then
    rm "$build_dir/native_options.next"
else
    mv "$build_dir/native_options.next" "$build_dir/native_options.zig"
fi
"$zig" cc -c -target riscv32-freestanding-none -mcpu="$cpu" -mabi="$abi" \
    -O2 -std=c11 -Wall -Wextra -Wconversion -Werror -ffreestanding \
    -I "$repo_root/include" -o "$build_dir/c_allocator.o" "$repo_root/probes/allocator/c_probe.c"
set -- "$build_dir/c_allocator.o"
"$zig" cc -c -target riscv32-freestanding-none -mcpu="$cpu" -mabi="$abi" \
    -Os -std=gnu17 -ffreestanding -fno-builtin -fno-pic -DNIH_NATIVE_CARD_READ="$card_read_cpp" \
    -o "$build_dir/base_sram.o" "$repo_root/src/platform/native/base_sram.c"
set -- "$@" "$build_dir/base_sram.o"
if [ "$graphics" = true ]; then
    sh "$repo_root/tools/build-native-graphics-payload.sh" "$build_dir"
    set -- "$@" "$build_dir/graphics_payload.o" "$build_dir/graphics_fonts.o"
fi
if [ "$display" = true ] || [ "$psram_200" = true ]; then
    idf_path=${NIHOS_IDF_PATH:-${IDF_PATH:-"$HOME/esp32/esp-idf-v5.4.4"}}
    headers="$repo_root/.tools/zig-0.17.0/lib/libc/include"
    sdmmc_pads=0
    if [ "$sdmmc" = true ]; then sdmmc_pads=1; fi
    "$zig" cc -c -target riscv32-freestanding-none -mcpu="$cpu" -mabi="$abi" \
        -O2 -std=gnu17 -ffreestanding -fno-builtin -fno-pic \
        -DNIH_NATIVE_REV3="$rev3" -DNIH_NATIVE_SDMMC_PADS="$sdmmc_pads" \
        -isystem "$headers/riscv32-linux-musl" -isystem "$headers/generic-musl" \
        -isystem "$headers/riscv-linux-any" \
        -I "$native_boot_dir/loader/config" \
        -I "$idf_path/components/hal/include" -I "$idf_path/components/hal/platform_port/include" \
        -I "$idf_path/components/hal/esp32p4/include" -I "$idf_path/components/soc/include" \
        -I "$idf_path/components/soc/esp32p4/include" -I "$idf_path/components/soc/esp32p4/register/hw_ver1" \
        -I "$idf_path/components/esp_common/include" -I "$idf_path/components/esp_hw_support/include" \
        -I "$idf_path/components/esp_rom/include" -I "$idf_path/components/esp_rom/esp32p4/include" -I "$idf_path/components/esp_rom/esp32p4/include/esp32p4" \
        -I "$idf_path/components/esp_rom/esp32p4" \
        -o "$build_dir/display_pads.o" "$repo_root/src/board/tab5/native_pads.c"
    set -- "$@" "$build_dir/display_pads.o"
    if [ "$audio" = true ] || [ "$devices" = true ]; then
        "$zig" cc -c -target riscv32-freestanding-none -mcpu="$cpu" -mabi="$abi" \
            -Os -std=gnu17 -ffreestanding -fno-builtin -fno-pic -ffunction-sections -fdata-sections \
            -isystem "$headers/riscv32-linux-musl" -isystem "$headers/generic-musl" -isystem "$headers/riscv-linux-any" \
            -I "$native_boot_dir/loader/config" \
            -I "$idf_path/components/hal/include" -I "$idf_path/components/hal/platform_port/include" \
            -I "$idf_path/components/hal/esp32p4/include" -I "$idf_path/components/soc/include" \
            -I "$idf_path/components/soc/esp32p4/include" -I "$idf_path/components/soc/esp32p4/register/hw_ver1" \
            -I "$idf_path/components/esp_common/include" -I "$idf_path/components/esp_hw_support/include" \
            -o "$build_dir/audio_tx.o" "$repo_root/probes/audio_native/tx.c"
        set -- "$@" "$build_dir/audio_tx.o"
    fi
    if [ "$microphone" = true ] || [ "$devices" = true ]; then
        "$zig" cc -c -target riscv32-freestanding-none -mcpu="$cpu" -mabi="$abi" \
            -Os -std=gnu17 -ffreestanding -fno-builtin -fno-pic -ffunction-sections -fdata-sections \
            -isystem "$headers/riscv32-linux-musl" -isystem "$headers/generic-musl" -isystem "$headers/riscv-linux-any" \
            -I "$native_boot_dir/loader/config" \
            -I "$idf_path/components/hal/include" -I "$idf_path/components/hal/platform_port/include" \
            -I "$idf_path/components/hal/esp32p4/include" -I "$idf_path/components/soc/include" \
            -I "$idf_path/components/soc/esp32p4/include" -I "$idf_path/components/soc/esp32p4/register/hw_ver1" \
            -I "$idf_path/components/esp_common/include" -I "$idf_path/components/esp_hw_support/include" \
            -o "$build_dir/microphone_rx.o" "$repo_root/probes/microphone_native/rx.c"
        set -- "$@" "$build_dir/microphone_rx.o"
    fi
    if [ "$rs485" = true ] || [ "$devices" = true ]; then
        "$zig" cc -c -target riscv32-freestanding-none -mcpu="$cpu" -mabi="$abi" \
            -Os -std=gnu17 -ffreestanding -fno-builtin -fno-pic -ffunction-sections -fdata-sections \
            -isystem "$headers/riscv32-linux-musl" -isystem "$headers/generic-musl" -isystem "$headers/riscv-linux-any" \
            -I "$native_boot_dir/loader/config" \
            -I "$idf_path/components/hal/include" -I "$idf_path/components/hal/platform_port/include" \
            -I "$idf_path/components/hal/esp32p4/include" -I "$idf_path/components/soc/include" \
            -I "$idf_path/components/soc/esp32p4/include" -I "$idf_path/components/soc/esp32p4/register/hw_ver1" \
            -I "$idf_path/components/esp_common/include" -I "$idf_path/components/esp_hw_support/include" \
            -o "$build_dir/rs485_uart.o" "$repo_root/probes/rs485_native/uart.c"
        set -- "$@" "$build_dir/rs485_uart.o"
    fi
    if [ "$display_scanout" = true ]; then
        "$zig" cc -c -target riscv32-freestanding-none -mcpu="$cpu" -mabi="$abi" \
            -Os -std=gnu17 -ffreestanding -fno-builtin -fno-pic -DNIH_NATIVE_DISPLAY_TILE="$display_tile_cpp" -DNIH_NATIVE_KEYPAD="$keypad_cpp" -DNIH_NATIVE_CARD_READ="$card_read_cpp" -DNIH_NATIVE_PHOTO="$photo_cpp" -DNIH_NATIVE_CARD_AUTO="$card_auto" -DNIH_NATIVE_CARD_SCENE_EXERCISE="$scene_exercise" \
            -isystem "$headers/riscv32-linux-musl" -isystem "$headers/generic-musl" \
            -isystem "$headers/riscv-linux-any" \
            -I "$native_boot_dir/loader/config" \
            -I "$idf_path/components/hal/include" -I "$idf_path/components/hal/platform_port/include" \
            -I "$idf_path/components/hal/esp32p4/include" -I "$idf_path/components/soc/include" \
            -I "$idf_path/components/soc/esp32p4/include" -I "$idf_path/components/soc/esp32p4/register/hw_ver1" \
            -I "$idf_path/components/esp_common/include" -I "$idf_path/components/esp_hw_support/include" \
            -o "$build_dir/display_scanout.o" "$repo_root/src/board/tab5/native_scanout.c"
        set -- "$@" "$build_dir/display_scanout.o"
    fi
fi
if [ "$sdmmc" = true ] || [ "$network" = true ]; then
    pad_source="$repo_root/probes/sdmmc/pads.c"
    if [ "$network" = true ]; then pad_source="$repo_root/probes/c6-sdio/pads.c"; fi
    idf_path=${NIHOS_IDF_PATH:-${IDF_PATH:-"$HOME/esp32/esp-idf-v5.4.4"}}
    register_version=hw_ver1
    if [ "$profile" = emulator ]; then register_version=hw_ver3; fi
    headers="$repo_root/.tools/zig-0.17.0/lib/libc/include"
    "$zig" cc -c -target riscv32-freestanding-none -mcpu="$cpu" -mabi="$abi" \
        -O2 -std=gnu17 -ffreestanding -fno-builtin -fno-pic \
        -isystem "$headers/riscv32-linux-musl" -isystem "$headers/generic-musl" \
        -isystem "$headers/riscv-linux-any" \
        -I "$native_boot_dir/loader/config" \
        -I "$idf_path/components/hal/include" -I "$idf_path/components/hal/platform_port/include" \
        -I "$idf_path/components/hal/esp32p4/include" -I "$idf_path/components/soc/include" \
        -I "$idf_path/components/soc/esp32p4/include" -I "$idf_path/components/soc/esp32p4/register/$register_version" \
        -I "$idf_path/components/esp_common/include" -I "$idf_path/components/esp_hw_support/include" \
        -I "$idf_path/components/esp_rom/include" -I "$idf_path/components/esp_rom/esp32p4/include" -I "$idf_path/components/esp_rom/esp32p4/include/esp32p4" \
        -I "$idf_path/components/esp_rom/esp32p4" \
        -o "$build_dir/sdmmc_pads.o" "$pad_source"
    set -- "$@" "$build_dir/sdmmc_pads.o"
fi

if [ "$usb" = true ]; then
    idf_path=${NIHOS_IDF_PATH:-${IDF_PATH:-"$HOME/esp32/esp-idf-v5.4.4"}}
    register_version=hw_ver1
    if [ "$profile" = emulator ]; then register_version=hw_ver3; fi
    headers="$repo_root/.tools/zig-0.17.0/lib/libc/include"
    "$zig" cc -c -target riscv32-freestanding-none -mcpu="$cpu" -mabi="$abi" \
        -O2 -std=gnu17 -ffreestanding -fno-builtin -fno-pic \
        -isystem "$headers/riscv32-linux-musl" -isystem "$headers/generic-musl" \
        -isystem "$headers/riscv-linux-any" \
        -I "$repo_root/build/native-$profile/loader/config" \
        -I "$idf_path/components/hal/include" -I "$idf_path/components/hal/platform_port/include" \
        -I "$idf_path/components/hal/esp32p4/include" -I "$idf_path/components/soc/include" \
        -I "$idf_path/components/soc/esp32p4/include" -I "$idf_path/components/soc/esp32p4/register/$register_version" \
        -I "$idf_path/components/esp_common/include" -I "$idf_path/components/esp_hw_support/include" \
        -I "$idf_path/components/esp_rom/include" -I "$idf_path/components/esp_rom/esp32p4/include" \
        -I "$idf_path/components/esp_rom/esp32p4" \
        -o "$build_dir/usb_pads.o" "$repo_root/probes/usb_native/pads.c"
    set -- "$@" "$build_dir/usb_pads.o"
fi
if [ "$card_photo" = true ]; then
    sh "$repo_root/tools/build-photo-codec.sh" "$build_dir" rv32
    "$zig" cc -c -target riscv32-freestanding-none -mcpu="$cpu" -mabi="$abi" \
        "$repo_root/probes/photo/stack.S" -o "$build_dir/photo_stack.o"
    set -- "$@" "$build_dir"/photo_*.o
    if [ "$card_auto" = true ] && [ "$auto_probe" = false ]; then
        "$zig" build-obj -target riscv32-freestanding-none -mcpu="$cpu" -O small -fllvm \
            -ffunction-sections -fdata-sections -fno-stack-check -fno-stack-protector \
            -femit-bin="$build_dir/card_crypto.o" \
            --dep crypto -Mroot="$repo_root/probes/card_crypto/link.zig" \
            -target riscv32-freestanding-none -mcpu="$cpu" -O small \
            -Mcrypto="$repo_root/src/card/license_crypto.zig"
        "$zig" cc -c -target riscv32-freestanding-none -mcpu="$cpu" -mabi="$abi" \
            "$repo_root/probes/card_crypto/stack.S" -o "$build_dir/card_crypto_stack.o"
        set -- "$@" "$build_dir/card_crypto.o" "$build_dir/card_crypto_stack.o"
    fi
fi
if [ "$floating" = true ]; then
    "$zig" cc -c -target riscv32-freestanding-none \
        -mcpu=generic_rv32+m+a+c+f+zicsr+zifencei -mabi="$abi" -I "$repo_root/src/kernel" \
        -o "$build_dir/fpu.o" "$repo_root/src/arch/riscv32/fpu.S"
    set -- "$@" "$build_dir/fpu.o"
fi
if [ "$mode" = compiled ]; then
    "$zig" cc -c -target riscv32-freestanding-none -mcpu="$cpu" -mabi="$abi" \
        -O2 -std=c11 -Wall -Wextra -Wconversion -Werror -ffp-contract=off \
        -o "$build_dir/c_math.o" "$repo_root/probes/native_fp/c_math.c"
    set -- "$@" "$build_dir/c_math.o"
fi
if [ "$sqlite" = true ]; then
    source_dir=$(sh "$repo_root/tools/bootstrap-sqlite.sh")
    headers="$repo_root/.tools/zig-0.17.0/lib/libc/include"
    for name in sqlite3 session vfs strings; do
        case "$name" in
            sqlite3) source="$source_dir/sqlite3.c" ;;
            session) source="$repo_root/src/services/sqlite_session.c" ;;
            vfs) source="$repo_root/probes/sqlite/noio_vfs.c" ;;
            strings) source="$repo_root/src/compat/c_strings.c" ;;
        esac
        "$zig" cc -c -target riscv32-freestanding-none -mcpu="$cpu" -mabi="$abi" \
            -Oz -std=c11 -ffreestanding -fno-builtin -fno-pic -ffunction-sections -fdata-sections \
            -fno-stack-protector -fno-unwind-tables -fno-asynchronous-unwind-tables -fstack-size-section \
            -isystem "$headers/riscv32-linux-musl" -isystem "$headers/generic-musl" \
            -isystem "$headers/riscv-linux-any" -I "$repo_root/include" -I "$source_dir" \
            -DNIH_SQLITE_NATIVE_PROBE -DSQLITE_THREADSAFE=0 -DSQLITE_ZERO_MALLOC=1 -DSQLITE_OS_OTHER=1 \
            -DSQLITE_TEMP_STORE=3 -DSQLITE_DEFAULT_PAGE_SIZE=1024 -DSQLITE_DEFAULT_MEMSTATUS=1 \
            -DSQLITE_OMIT_LOCALTIME -DSQLITE_OMIT_LOAD_EXTENSION -DSQLITE_OMIT_WAL \
            -DSQLITE_OMIT_AUTOINIT -DSQLITE_OMIT_LOOKASIDE -DSQLITE_ENABLE_API_ARMOR \
            "$source" -o "$build_dir/sql_$name.o"
        set -- "$@" "$build_dir/sql_$name.o"
    done
    "$zig" cc -c -target riscv32-freestanding-none -mcpu="$cpu" -mabi="$abi" \
        "$repo_root/probes/sqlite/stack_paint.S" -o "$build_dir/sql_stack_paint.o"
    set -- "$@" "$build_dir/sql_stack_paint.o"
    littlefs_source=
    if [ "$storage" = true ]; then
        littlefs_source=$(sh "$repo_root/tools/bootstrap-littlefs.sh")
        for name in lfs lfs_util lfs_reader; do
            source="$littlefs_source/$name.c"
            if [ "$name" = lfs_reader ]; then source="$repo_root/probes/storage/littlefs_ro.c"; fi
            "$zig" cc -c -target riscv32-freestanding-none -mcpu="$cpu" -mabi="$abi" \
                -Oz -std=c11 -ffreestanding -fno-builtin -fno-pic -ffunction-sections -fdata-sections \
                -fno-stack-protector -fno-unwind-tables -fno-asynchronous-unwind-tables -fstack-size-section \
                -isystem "$headers/riscv32-linux-musl" -isystem "$headers/generic-musl" \
                -isystem "$headers/riscv-linux-any" -I "$littlefs_source" -I "$repo_root/include" \
                -DLFS_READONLY -DLFS_NO_MALLOC -DLFS_NO_ASSERT -DLFS_NO_DEBUG -DLFS_NO_WARN -DLFS_NO_ERROR \
                "$source" -o "$build_dir/sql_$name.o"
            set -- "$@" "$build_dir/sql_$name.o"
        done
        python3 "$repo_root/tools/native-sqlite-manifest.py" "$build_dir" "$source_dir" "$littlefs_source"
    else
        python3 "$repo_root/tools/native-sqlite-manifest.py" "$build_dir" "$source_dir"
    fi
fi
"$zig" build-exe -target riscv32-freestanding-none \
    -mcpu="$cpu" -O safe -fllvm -ffunction-sections -fno-strip \
    -fno-stack-check -fno-stack-protector -fno-unwind-tables \
    -fentry=nih_native_start -T "$build_dir/native-layout.ld" \
    -DNIH_NATIVE_REV3="$rev3" -DNIH_NATIVE_FLOATING="$fp_asm" -DNIH_NATIVE_DISPLAY_SCANOUT="$display_boot_cpp" -DNIH_NATIVE_GRAPHICS="$graphics_cpp" --gc-sections \
    -I "$repo_root/src/arch/riscv32" -I "$repo_root/src/kernel" \
    "$repo_root/src/platform/native/start.S" "$@" \
    -target riscv32-freestanding-none -mcpu="$cpu" -O "$root_opt" \
    --dep native_options --dep timer_group --dep native_tasks --dep psram --dep psram_supply --dep psram_mpll --dep psram_tuning --dep psram_mapping --dep record_log --dep sdmmc --dep block_reader --dep boot_i2c --dep tab5_rtc --dep tab5_bmi270 --dep half_duplex --dep pointer_input --dep device_control --dep native_memory --dep tab5_es8388 --dep tab5_es7210 --dep microphone_model --dep audio_tone --dep audio_probe_model --dep ccid --dep jpki --dep card --dep usb_host --dep usb_descriptors --dep tab5_display --dep boot_graphics --dep tab5_panels --dep display_dcs --dep scanout_state --dep text_console --dep display_service --dep cpu_boot --dep network_service --dep network_config -Mroot="$repo_root/src/platform/native/main.zig" \
    -Mpointer_input="$repo_root/src/input/pointer.zig" \
    -Mdevice_control="$repo_root/src/device/control.zig" \
    -Mtab5_rtc="$repo_root/src/board/tab5/rtc.zig" \
    -Mtab5_bmi270="$repo_root/src/board/tab5/bmi270.zig" \
    -Mhalf_duplex="$repo_root/src/serial/half_duplex.zig" \
    -Mtab5_es7210="$repo_root/src/board/tab5/es7210.zig" \
    -Mmicrophone_model="$repo_root/src/audio/capture_probe.zig" \
    -Mtab5_es8388="$repo_root/src/board/tab5/es8388.zig" \
    -Maudio_tone="$repo_root/src/audio/tone.zig" \
    -Maudio_probe_model="$repo_root/src/audio/playback_probe.zig" \
    -target riscv32-freestanding-none -mcpu="$cpu" -O small \
    --dep native_options --dep timer_group --dep c6_probe --dep sdio --dep c6_sdio --dep hosted_station -Mnetwork_service="$repo_root/src/platform/native/network_service.zig" \
    -target riscv32-freestanding-none -mcpu="$cpu" -O small \
    --dep timer_group --dep sdio --dep c6_sdio --dep at_controller --dep hosted_station -Mc6_probe="$repo_root/src/platform/native/c6_probe.zig" \
    -target riscv32-freestanding-none -mcpu="$cpu" -O small \
    -Mnetwork_config="$build_dir/network-config.zig" \
    -target riscv32-freestanding-none -mcpu="$cpu" -O small \
    -Msdio="$repo_root/src/soc/esp32p4/sdio.zig" \
    -target riscv32-freestanding-none -mcpu="$cpu" -O small \
    -Mc6_sdio="$repo_root/src/net/c6_sdio.zig" \
    -target riscv32-freestanding-none -mcpu="$cpu" -O small \
    -Mat_controller="$repo_root/src/net/at_controller.zig" \
    -target riscv32-freestanding-none -mcpu="$cpu" -O small \
    -Mhosted_station="$repo_root/src/net/hosted_station.zig" \
    -target riscv32-freestanding-none -mcpu="$cpu" -O small \
    --dep native_options --dep timer_group --dep native_tasks --dep boot_i2c --dep ccid --dep jpki --dep card --dep usb_host --dep usb_descriptors --dep pointer_input --dep device_control --dep tab5_display --dep boot_graphics --dep tab5_panels --dep display_dcs --dep scanout_state --dep text_console \
    -Mdisplay_service="$repo_root/src/platform/native/display_service.zig" \
    -target riscv32-freestanding-none -mcpu="$cpu" -O small \
    --dep cpu_clock --dep timer_group -Mcpu_boot="$repo_root/src/platform/native/cpu_boot.zig" \
    -target riscv32-freestanding-none -mcpu="$cpu" -O small \
    -Mcpu_clock="$repo_root/src/soc/esp32p4/cpu_clock.zig" \
    -target riscv32-freestanding-none -mcpu="$cpu" -O safe \
    -Mccid="$repo_root/src/usb/ccid.zig" \
    -target riscv32-freestanding-none -mcpu="$cpu" -O safe \
    --dep ccid --dep surface -Mcard="$repo_root/src/card.zig" \
    -target riscv32-freestanding-none -mcpu="$cpu" -O safe \
    -Mjpki="$repo_root/src/usb/jpki.zig" \
    -target riscv32-freestanding-none -mcpu="$cpu" -O safe \
    -Musb_host="$repo_root/src/soc/esp32p4/usb_host.zig" \
    -target riscv32-freestanding-none -mcpu="$cpu" -O safe \
    -Musb_descriptors="$repo_root/src/usb/descriptors.zig" \
    -target riscv32-freestanding-none -mcpu="$cpu" -O small \
    -Mtab5_panels="$repo_root/src/board/tab5/panels.zig" \
    -target riscv32-freestanding-none -mcpu="$cpu" -O small \
    -Mdisplay_dcs="$repo_root/src/board/tab5/dcs.zig" \
    -target riscv32-freestanding-none -mcpu="$cpu" -O small \
    -Mscanout_state="$repo_root/src/board/tab5/scanout_state.zig" \
    -target riscv32-freestanding-none -mcpu="$cpu" -O small \
    -Mboot_i2c="$repo_root/src/board/tab5/boot_i2c.zig" \
    -target riscv32-freestanding-none -mcpu="$cpu" -O small \
    -Mtab5_display="$repo_root/src/board/tab5/display.zig" \
    -target riscv32-freestanding-none -mcpu="$cpu" -O small \
    -Mtext_console="$repo_root/src/console.zig" \
    -target riscv32-freestanding-none -mcpu="$cpu" -O small \
    -Mboot_graphics="$repo_root/src/graphics/boot_graphics.zig" \
    -target riscv32-freestanding-none -mcpu="$cpu" -O safe \
    -Mblock_reader="$repo_root/src/storage/block.zig" \
    -target riscv32-freestanding-none -mcpu="$cpu" -O safe \
    -Msdmmc="$repo_root/src/soc/esp32p4/sdmmc.zig" \
    -target riscv32-freestanding-none -mcpu="$cpu" -O safe \
    -Mrecord_log="$repo_root/src/diagnostics/record.zig" \
    -target riscv32-freestanding-none -mcpu="$cpu" -O safe \
    -Mtimer_group="$repo_root/src/soc/esp32p4/timer_group.zig" \
    -target riscv32-freestanding-none -mcpu="$cpu" -O safe \
    --dep scheduler --dep task_control --dep tick_clock --dep timer_group \
    --dep remote_events --dep spsc_ring --dep spsc_mailbox --dep spsc_channel --dep text_context --dep font_stack_lifetime --dep raster_lease --dep surface --dep software_ipi --dep park --dep native_options --dep fp_vectors --dep native_memory \
    -Mnative_tasks="$repo_root/src/arch/riscv32/native_tasks.zig" \
    -target riscv32-freestanding-none -mcpu="$cpu" -O safe \
    -Mscheduler="$repo_root/src/kernel/scheduler.zig" \
    -target riscv32-freestanding-none -mcpu="$cpu" -O safe \
    -Mtask_control="$repo_root/src/kernel/task_control.zig" \
    -target riscv32-freestanding-none -mcpu="$cpu" -O safe \
    -Mtick_clock="$repo_root/src/kernel/tick_clock.zig" \
    -target riscv32-freestanding-none -mcpu="$cpu" -O safe \
    -Mremote_events="$repo_root/src/kernel/remote_events.zig" \
    -target riscv32-freestanding-none -mcpu="$cpu" -O safe \
    -Mspsc_ring="$repo_root/src/kernel/spsc_ring.zig" \
    -target riscv32-freestanding-none -mcpu="$cpu" -O safe \
    -Mspsc_mailbox="$repo_root/src/kernel/spsc_mailbox.zig" \
    -target riscv32-freestanding-none -mcpu="$cpu" -O safe \
    -Mspsc_channel="$repo_root/src/kernel/spsc_channel.zig" \
    -target riscv32-freestanding-none -mcpu="$cpu" -O safe \
    -Mraster_lease="$repo_root/src/graphics/raster_lease.zig" \
    -target riscv32-freestanding-none -mcpu="$cpu" -O safe \
    -Msurface="$repo_root/src/graphics/surface.zig" \
    -target riscv32-freestanding-none -mcpu="$cpu" -O safe \
    -Mfont_stack_lifetime="$repo_root/src/graphics/font_stack_lifetime.zig" \
    -target riscv32-freestanding-none -mcpu="$cpu" -O safe \
    -Mtext_context="$repo_root/src/graphics/text_context.zig" \
    -target riscv32-freestanding-none -mcpu="$cpu" -O safe \
    -Msoftware_ipi="$repo_root/src/soc/esp32p4/software_ipi.zig" \
    -target riscv32-freestanding-none -mcpu="$cpu" -O safe \
    -Mpark="$repo_root/src/kernel/park.zig" \
    -Mnative_options="$build_dir/native_options.zig" \
    -target riscv32-freestanding-none -mcpu="$cpu" -O safe \
    -Mfp_vectors="$repo_root/src/kernel/fp_vectors.zig" \
    -target riscv32-freestanding-none -mcpu="$cpu" -O safe \
    --dep native_options --dep core_arena --dep buddy_heap --dep task_resources -Mnative_memory="$repo_root/src/platform/native/memory.zig" \
    -target riscv32-freestanding-none -mcpu="$cpu" -O safe \
    -Mcore_arena="$repo_root/src/kernel/core_arena.zig" \
    -target riscv32-freestanding-none -mcpu="$cpu" -O safe \
    -Mbuddy_heap="$repo_root/src/kernel/buddy_heap.zig" \
    -target riscv32-freestanding-none -mcpu="$cpu" -O safe \
    -Mtask_resources="$repo_root/src/kernel/task_resources.zig" \
    -target riscv32-freestanding-none -mcpu="$cpu" -O safe \
    -Mpsram="$repo_root/src/soc/esp32p4/psram.zig" \
    -target riscv32-freestanding-none -mcpu="$cpu" -O safe \
    -Mpsram_tuning="$repo_root/src/soc/esp32p4/psram_tuning.zig" \
    -Mpsram_mpll="$repo_root/src/soc/esp32p4/psram_mpll.zig" \
    -Mpsram_supply="$repo_root/src/soc/esp32p4/psram_supply.zig" \
    -target riscv32-freestanding-none -mcpu="$cpu" -O safe \
    -Mpsram_mapping="$repo_root/src/soc/esp32p4/psram_mapping.zig" \
    -target riscv32-freestanding-none -mcpu="$cpu" -O safe \
    -femit-bin="$build_dir/nihos-native.elf"

if [ "$card_photo" = true ]; then python3 "$repo_root/tools/native-photo-manifest.py" "$build_dir"; fi
