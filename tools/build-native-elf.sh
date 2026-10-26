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
    floating) floating=true; fp_asm=1 ;;
    compiled) floating=true; fp_asm=1; compiled=true; cpu=generic_rv32+m+a+c+f+zicsr+zifencei; abi=ilp32f ;;
    *) echo "mode must be integer, floating, compiled or sqlite" >&2; exit 1 ;;
esac
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
display_boot_cpp=0
display_tile_cpp=0
case "$display" in
    0) display=false ;;
    1) display=true ;;
    2) display=true; display_scanout=true ;;
    3) display=true; display_scanout=true; display_white=true ;;
    4) display=true; display_scanout=true; display_white=true; display_pattern=true ;;
    5) display=true; display_scanout=true; display_white=true; display_sram=true ;;
    6) display=true; display_scanout=true; display_sram=true; display_tile=true ;;
    7) display=true; display_scanout=true; display_sram=true; display_tile=true; display_scene=true ;;
    *) echo "NIHOS_NATIVE_DISPLAY must be 0, 1, 2, 3, 4, 5, 6 or 7" >&2; exit 1 ;;
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
if [ "$display_scanout" = true ]; then display_boot_cpp=1; fi
if [ "$display_tile" = true ]; then display_tile_cpp=1; fi
if [ "$display" = true ] && [ "$profile" != device ]; then
    echo "Native display preparation requires the physical-device profile" >&2
    exit 1
fi
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
mkdir -p "$build_dir"
"$zig" cc -E -P -x c -DNIH_NATIVE_REV3="$rev3" -DNIH_NATIVE_SQLITE="$sqlite_cpp" \
    "$repo_root/src/platform/native/esp32p4.ld" -o "$build_dir/native-layout.ld"
printf 'pub const floating = %s;\npub const compiled = %s;\npub const sqlite = %s;\npub const qualification = %s;\npub const sdmmc = %s;\npub const sdmmc_profile: u32 = %s;\npub const storage = %s;\npub const display = %s;\npub const display_scanout = %s;\npub const display_white = %s;\npub const display_pattern = %s;\npub const display_sram = %s;\npub const display_tile = %s;\npub const display_scene = %s;\npub const psram_mpll = %s;\npub const psram_200 = %s;\npub const display_hz: u32 = %s;\npub const console = %s;\npub const console_palette: u32 = %s;\npub const console_font: u32 = %s;\npub const console_live = %s;\npub const keyboard_i2c = %s;\npub const console_fault = %s;\n' "$floating" "$compiled" "$sqlite" "$qualification" "$sdmmc" "$sdmmc_profile" "$storage" "$display" "$display_scanout" "$display_white" "$display_pattern" "$display_sram" "$display_tile" "$display_scene" "$psram_mpll" "$psram_200" "$display_hz" "$console" "$console_palette" "$console_font" "$console_live" "$keyboard_i2c" "$console_fault" > "$build_dir/native_options.next"
printf 'pub const cpu_mhz: u32 = %s;\n' "$cpu_mhz" >> "$build_dir/native_options.next"
if cmp -s "$build_dir/native_options.next" "$build_dir/native_options.zig"; then
    rm "$build_dir/native_options.next"
else
    mv "$build_dir/native_options.next" "$build_dir/native_options.zig"
fi
"$zig" cc -c -target riscv32-freestanding-none -mcpu="$cpu" -mabi="$abi" \
    -O2 -std=c11 -Wall -Wextra -Wconversion -Werror -ffreestanding \
    -I "$repo_root/include" -o "$build_dir/c_allocator.o" "$repo_root/probes/allocator/c_probe.c"
set -- "$build_dir/c_allocator.o"
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
        -I "$repo_root/build/native-$profile/loader/config" \
        -I "$idf_path/components/hal/include" -I "$idf_path/components/hal/platform_port/include" \
        -I "$idf_path/components/hal/esp32p4/include" -I "$idf_path/components/soc/include" \
        -I "$idf_path/components/soc/esp32p4/include" -I "$idf_path/components/soc/esp32p4/register/hw_ver1" \
        -I "$idf_path/components/esp_common/include" -I "$idf_path/components/esp_hw_support/include" \
        -I "$idf_path/components/esp_rom/include" -I "$idf_path/components/esp_rom/esp32p4/include" -I "$idf_path/components/esp_rom/esp32p4/include/esp32p4" \
        -I "$idf_path/components/esp_rom/esp32p4" \
        -o "$build_dir/display_pads.o" "$repo_root/src/board/tab5/native_pads.c"
    set -- "$@" "$build_dir/display_pads.o"
    if [ "$display_scanout" = true ]; then
        "$zig" cc -c -target riscv32-freestanding-none -mcpu="$cpu" -mabi="$abi" \
            -Os -std=gnu17 -ffreestanding -fno-builtin -fno-pic -DNIH_NATIVE_DISPLAY_TILE="$display_tile_cpp" \
            -isystem "$headers/riscv32-linux-musl" -isystem "$headers/generic-musl" \
            -isystem "$headers/riscv-linux-any" \
            -I "$repo_root/build/native-$profile/loader/config" \
            -I "$idf_path/components/hal/include" -I "$idf_path/components/hal/platform_port/include" \
            -I "$idf_path/components/hal/esp32p4/include" -I "$idf_path/components/soc/include" \
            -I "$idf_path/components/soc/esp32p4/include" -I "$idf_path/components/soc/esp32p4/register/hw_ver1" \
            -I "$idf_path/components/esp_common/include" -I "$idf_path/components/esp_hw_support/include" \
            -o "$build_dir/display_scanout.o" "$repo_root/src/board/tab5/native_scanout.c"
        set -- "$@" "$build_dir/display_scanout.o"
    fi
fi
if [ "$sdmmc" = true ]; then
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
        -I "$idf_path/components/esp_rom/include" -I "$idf_path/components/esp_rom/esp32p4/include" -I "$idf_path/components/esp_rom/esp32p4/include/esp32p4" \
        -I "$idf_path/components/esp_rom/esp32p4" \
        -o "$build_dir/sdmmc_pads.o" "$repo_root/probes/sdmmc/pads.c"
    set -- "$@" "$build_dir/sdmmc_pads.o"
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
    -mcpu="$cpu" -O safe -fllvm -fno-strip \
    -fno-stack-check -fno-stack-protector -fno-unwind-tables \
    -fentry=nih_native_start -T "$build_dir/native-layout.ld" \
    -DNIH_NATIVE_REV3="$rev3" -DNIH_NATIVE_FLOATING="$fp_asm" -DNIH_NATIVE_DISPLAY_SCANOUT="$display_boot_cpp" --gc-sections \
    -I "$repo_root/src/arch/riscv32" -I "$repo_root/src/kernel" \
    "$repo_root/src/platform/native/start.S" "$@" \
    -target riscv32-freestanding-none -mcpu="$cpu" -O safe \
    --dep native_options --dep timer_group --dep native_tasks --dep psram --dep psram_supply --dep psram_mpll --dep psram_tuning --dep psram_mapping --dep record_log --dep sdmmc --dep block_reader --dep boot_i2c --dep tab5_display --dep boot_graphics --dep tab5_panels --dep display_dcs --dep scanout_state --dep text_console --dep display_service --dep cpu_boot -Mroot="$repo_root/src/platform/native/main.zig" \
    -target riscv32-freestanding-none -mcpu="$cpu" -O small \
    --dep native_options --dep timer_group --dep native_tasks --dep boot_i2c --dep tab5_display --dep boot_graphics --dep tab5_panels --dep display_dcs --dep scanout_state --dep text_console \
    -Mdisplay_service="$repo_root/src/platform/native/display_service.zig" \
    -target riscv32-freestanding-none -mcpu="$cpu" -O small \
    --dep cpu_clock --dep timer_group -Mcpu_boot="$repo_root/src/platform/native/cpu_boot.zig" \
    -target riscv32-freestanding-none -mcpu="$cpu" -O small \
    -Mcpu_clock="$repo_root/src/soc/esp32p4/cpu_clock.zig" \
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
    --dep remote_events --dep spsc_ring --dep software_ipi --dep park --dep native_options --dep fp_vectors --dep native_memory \
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
    -Msoftware_ipi="$repo_root/src/soc/esp32p4/software_ipi.zig" \
    -target riscv32-freestanding-none -mcpu="$cpu" -O safe \
    -Mpark="$repo_root/src/kernel/park.zig" \
    -Mnative_options="$build_dir/native_options.zig" \
    -target riscv32-freestanding-none -mcpu="$cpu" -O safe \
    -Mfp_vectors="$repo_root/src/kernel/fp_vectors.zig" \
    -target riscv32-freestanding-none -mcpu="$cpu" -O safe \
    --dep core_arena --dep buddy_heap --dep task_resources -Mnative_memory="$repo_root/src/platform/native/memory.zig" \
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
