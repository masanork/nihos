#!/bin/sh
# Reproduce bounded direct-app checks for the identified shi3z MeOS build.
set -eu

usage() {
    cat <<'HELP'
Usage: tools/run-meos-emulator-probe.sh shell|wasm|display-init|display-shell|display-snake MEOS_BUILD_DIR ROM_ELF

Runs a test-only MeOS direct-app fixture using the identified 956a0f3 build.
The shell scenario checks a serial echo; wasm checks three display API calls.
display-init checks the first black ST7121 fixture frame and missing refreshes.
display-shell checks repeated scanout and a serial shell response for that fixture.
display-snake checks wasm Snake drawing in that fixture's scanout.
This does not provide an interactive MeOS app, a display, or persistent flash.
HELP
}

if [ "${1:-}" = --help ] || [ "${1:-}" = -h ]; then usage; exit 0; fi
if [ "$#" -ne 3 ]; then usage >&2; exit 2; fi
scenario=$1
build_dir=$2
rom_path=$3
case "$scenario" in shell|wasm|display-init|display-shell|display-snake) ;; *) usage >&2; exit 2;; esac

check_hash() {
    file=$1
    expected=$2
    [ -f "$file" ] || { printf 'Missing file: %s\n' "$file" >&2; exit 1; }
    actual=$(shasum -a 256 "$file" | awk '{print $1}')
    [ "$actual" = "$expected" ] || {
        printf 'Unexpected SHA-256 for %s\nExpected: %s\nActual:   %s\n' "$file" "$expected" "$actual" >&2
        exit 1
    }
}
check_hash "$build_dir/m5os.bin" 2802acccea64410dee3e0caea5fd683d499a84b5818d76682580730ee7a1f09a
check_hash "$build_dir/m5os.elf" 6c5f827b436e00b268971f21a17ba9306391b74da68abfbe872ac75db5ea4e18
check_hash "$rom_path" 948f2c7d108d04a9c3a982f9c1c498fb17f2c4a68abc51f87782592034d7ce44

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
unset NIHOS_EMU_EXPECT_BUDGET NIHOS_EMU_EXPECT_BREAK_TEXT NIHOS_EMU_EXPECT_STOP NIHOS_EMU_STOP_ON_LOG
unset NIHOS_EMU_EXPECT_PC NIHOS_EMU_BREAK_HITS NIHOS_EMU_INPUT NIHOS_EMU_INPUT_AFTER
unset NIHOS_EMU_TEST_ST7121
unset NIHOS_EMU_EXPECT_SCANOUT_FRAMES
unset NIHOS_EMU_EXPECT_SCANOUT_NONZERO
unset NIHOS_EMU_EXPECT_SCANOUT_FRAMES_MIN NIHOS_EMU_EXPECT_SCANOUT_NONZERO_MIN
unset NIHOS_EMU_EXPECT_SCANOUT_PIXELS
unset NIHOS_EMU_CHECKPOINT_HITS NIHOS_EMU_EXPECT_CHECKPOINT_PIXELS
export NIHOS_EMU_ESP_APP="$build_dir/m5os.bin" NIHOS_EMU_ROM_ELF="$rom_path"
export NIHOS_EMU_USB_EMPTY=1 NIHOS_EMU_WASM_FLASH=1 NIHOS_EMU_BLANK_IME=1
export NIHOS_EMU_FLASH_CORE_80=1 NIHOS_EMU_EXEC_ROM=1 NIHOS_EMU_XTAL_40=1
export NIHOS_EMU_ROM_LAYOUT=0x4fc1d780 NIHOS_EMU_MAX_STEPS=500000000
export NIHOS_EMU_FORBID_LOG='overlaps with'
if [ "$scenario" = shell ]; then
    NIHOS_EMU_INPUT=$(printf 'echo EMU_REPLY_42\n_')
    NIHOS_EMU_INPUT=${NIHOS_EMU_INPUT%_}
    NIHOS_EMU_STOP_ON_LOG=$(printf '\r\nEMU_REPLY_42\r\n_')
    NIHOS_EMU_STOP_ON_LOG=${NIHOS_EMU_STOP_ON_LOG%_}
    export NIHOS_EMU_INPUT NIHOS_EMU_STOP_ON_LOG NIHOS_EMU_INPUT_AFTER='> '
    export NIHOS_EMU_EXPECT_FLASH_PROGRAMS_MIN=1
    export NIHOS_EMU_BREAK_PC=0x4ff00c98 NIHOS_EMU_EXPECT_LOG='PSRAM 28672 KB'
elif [ "$scenario" = wasm ]; then
    NIHOS_EMU_INPUT=$(printf 'run /apps/snake.wasm\n_')
    NIHOS_EMU_INPUT=${NIHOS_EMU_INPUT%_}
    export NIHOS_EMU_INPUT NIHOS_EMU_INPUT_AFTER='> ' NIHOS_EMU_BREAK_PC=0x4003c950 NIHOS_EMU_BREAK_HITS=3
    export NIHOS_EMU_EXPECT_FLASH_PROGRAMS_MIN=1
    export NIHOS_EMU_EXPECT_PC=0x4003c950 NIHOS_EMU_EXPECT_LOG='started /apps/snake.wasm as app'
elif [ "$scenario" = display-init ]; then
    unset NIHOS_EMU_EXPECT_FLASH_PROGRAMS_MIN
    export NIHOS_EMU_TEST_ST7121=1 NIHOS_EMU_MAX_STEPS=150000000
    NIHOS_EMU_STOP_ON_LOG=$(printf 'LCD: ok\r\n_')
    NIHOS_EMU_STOP_ON_LOG=${NIHOS_EMU_STOP_ON_LOG%_}
    export NIHOS_EMU_STOP_ON_LOG NIHOS_EMU_EXPECT_SCANOUT_FRAMES=1 NIHOS_EMU_EXPECT_SCANOUT_NONZERO=0
    export NIHOS_EMU_EXPECT_LOG='display: 0 refresh interrupts'
elif [ "$scenario" = display-shell ]; then
    NIHOS_EMU_INPUT=$(printf 'echo DISPLAY_READY_42\n_')
    NIHOS_EMU_INPUT=${NIHOS_EMU_INPUT%_}
    NIHOS_EMU_STOP_ON_LOG=$(printf '\r\nDISPLAY_READY_42\r\n_')
    NIHOS_EMU_STOP_ON_LOG=${NIHOS_EMU_STOP_ON_LOG%_}
    export NIHOS_EMU_TEST_ST7121=1 NIHOS_EMU_INPUT_AFTER='> ' NIHOS_EMU_INPUT NIHOS_EMU_STOP_ON_LOG
    export NIHOS_EMU_EXPECT_SCANOUT_FRAMES_MIN=2 NIHOS_EMU_EXPECT_SCANOUT_NONZERO_MIN=1
    export NIHOS_EMU_EXPECT_LOG='display: 0 refresh interrupts' NIHOS_EMU_EXPECT_FLASH_PROGRAMS_MIN=1
else
    NIHOS_EMU_INPUT=$(printf 'run /apps/snake.wasm\n_')
    NIHOS_EMU_INPUT=${NIHOS_EMU_INPUT%_}
    export NIHOS_EMU_TEST_ST7121=1 NIHOS_EMU_INPUT_AFTER='> ' NIHOS_EMU_INPUT
    export NIHOS_EMU_BREAK_PC=0x4003c950 NIHOS_EMU_BREAK_HITS=16 NIHOS_EMU_EXPECT_PC=0x4003c950
    export NIHOS_EMU_CHECKPOINT_HITS=12 NIHOS_EMU_EXPECT_CHECKPOINT_PIXELS='360,405,0x2d47;430,405,0x8ff1;157,200,0xce59'
    export NIHOS_EMU_EXPECT_SCANOUT_FRAMES_MIN=2 NIHOS_EMU_EXPECT_SCANOUT_PIXELS='360,405,0x0;430,405,0x2d47;157,200,0xce59'
    export NIHOS_EMU_EXPECT_LOG='started /apps/snake.wasm as app' NIHOS_EMU_EXPECT_FLASH_PROGRAMS_MIN=1
fi
exec cargo test --locked --manifest-path "$repo_dir/apps/xy-gpui/Cargo.toml" \
    inspect_external_app_execution -- --ignored --nocapture
