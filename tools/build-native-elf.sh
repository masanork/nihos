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
case "$storage" in
    0) storage=false ;;
    1) storage=true ;;
    *) echo "NIHOS_NATIVE_STORAGE must be 0 or 1" >&2; exit 1 ;;
esac
if [ "$storage" = true ] && { [ "$sdmmc" != true ] || [ "$sqlite" != true ]; }; then
    echo "Storage probe requires SDMMC=1 and sqlite mode (shared audited Flash span)" >&2
    exit 1
fi
high_sram=${NIHOS_NATIVE_HIGH_SRAM:-0}
case "$high_sram" in
    0) high_sram=false; high_cpp=0 ;;
    1) high_sram=true; high_cpp=1 ;;
    *) echo "NIHOS_NATIVE_HIGH_SRAM must be 0 or 1" >&2; exit 1 ;;
esac
storage_service=${NIHOS_NATIVE_STORAGE_SERVICE:-0}
broker=${NIHOS_NATIVE_MEMORY_BROKER:-0}
case "$broker" in
    0) broker=false ;;
    1) broker=true ;;
    *) echo "NIHOS_NATIVE_MEMORY_BROKER must be 0 or 1" >&2; exit 1 ;;
esac
if [ "$broker" = true ] && { [ "$high_sram" != true ] || [ "$profile" != device ] || [ "$sqlite" != true ] || [ "$storage_service" != 1 ]; }; then
    echo "Memory broker handoff requires device, sqlite, HIGH_SRAM=1 and STORAGE_SERVICE=1" >&2
    exit 1
fi
sd_removal=${NIHOS_NATIVE_SD_REMOVAL:-0}
case "$sd_removal" in
    0) sd_removal=false ;;
    1) sd_removal=true ;;
    *) echo "NIHOS_NATIVE_SD_REMOVAL must be 0 or 1" >&2; exit 1 ;;
esac
if [ "$sd_removal" = true ] && [ "$broker" != true ]; then
    echo "Physical SD removal qualification requires MEMORY_BROKER=1" >&2
    exit 1
fi
cold_capture=${NIHOS_NATIVE_COLD_CAPTURE:-0}
case "$cold_capture" in
    0) cold_capture=false; capture_cpp=0 ;;
    1) cold_capture=true; capture_cpp=1 ;;
    *) echo "NIHOS_NATIVE_COLD_CAPTURE must be 0 or 1" >&2; exit 1 ;;
esac
if [ "$cold_capture" = true ] && [ "$broker" != true ]; then
    echo "Cold capture handshake requires MEMORY_BROKER=1" >&2
    exit 1
fi
cold_flash=${NIHOS_NATIVE_COLD_FLASH:-0}
fatfs_native=${NIHOS_NATIVE_FATFS_RPC:-0}
fatfs_sd=${NIHOS_NATIVE_FATFS_SD:-0}
fatfs_sd_direct=${NIHOS_NATIVE_FATFS_SD_DIRECT:-0}
case "$fatfs_sd_direct" in
    0) fatfs_sd_direct=false ;;
    1) fatfs_sd_direct=true ;;
    *) echo "NIHOS_NATIVE_FATFS_SD_DIRECT must be 0 or 1" >&2; exit 1 ;;
esac
case "$fatfs_sd" in
    0) fatfs_sd=false ;;
    1) fatfs_sd=true ;;
    *) echo "NIHOS_NATIVE_FATFS_SD must be 0 or 1" >&2; exit 1 ;;
esac
case "$fatfs_native" in
    0) fatfs_native=false; fatfs_cpp=0 ;;
    1) fatfs_native=true; fatfs_cpp=1 ;;
    *) echo "NIHOS_NATIVE_FATFS_RPC must be 0 or 1" >&2; exit 1 ;;
esac
if [ "$fatfs_sd" = true ] && [ "$fatfs_native" != true ]; then
    echo "Native SD FatFs requires FATFS_RPC=1" >&2; exit 1
fi
if [ "$fatfs_sd_direct" = true ] && [ "$fatfs_sd" != true ]; then
    echo "Direct card boot requires FATFS_SD=1" >&2; exit 1
fi
if [ "$fatfs_native" = true ] && { [ "$broker" != true ] || [ "$sd_removal" = true ]; }; then
    echo "Native FatFs RPC fixture requires MEMORY_BROKER=1 and SD_REMOVAL=0" >&2
    exit 1
fi
case "$cold_flash" in
    0) cold_flash=false ;;
    1) cold_flash=true ;;
    *) echo "NIHOS_NATIVE_COLD_FLASH must be 0 or 1" >&2; exit 1 ;;
esac
if [ "$cold_flash" = true ] && [ "$broker" != true ]; then
    echo "Cold Flash placement requires MEMORY_BROKER=1" >&2
    exit 1
fi
if [ "$high_sram" = true ] && [ "$profile" != device ]; then
    echo "High SRAM qualification requires the device memory profile" >&2
    exit 1
fi
case "$storage_service" in
    0) storage_service=false ;;
    1) storage_service=true ;;
    *) echo "NIHOS_NATIVE_STORAGE_SERVICE must be 0 or 1" >&2; exit 1 ;;
esac
if [ "$storage_service" = true ] && { [ "$storage" != true ] || [ "$sdmmc_profile" != 2 ]; }; then
    echo "Storage service requires STORAGE=1, SDMMC=1, profile=2 and sqlite mode" >&2
    exit 1
fi
zig="$repo_root/.tools/zig-0.17.0/zig"
if [ ! -x "$zig" ]; then sh "$repo_root/tools/bootstrap-zig.sh" >/dev/null; fi
mkdir -p "$build_dir"
"$zig" cc -E -P -x c -DNIH_NATIVE_REV3="$rev3" -DNIH_NATIVE_SQLITE="$sqlite_cpp" -DNIH_NATIVE_HIGH_SRAM="$high_cpp" -DNIH_NATIVE_CAPTURE="$capture_cpp" -DNIH_NATIVE_FATFS_RPC="$fatfs_cpp" \
    "$repo_root/src/platform/native/esp32p4.ld" -o "$build_dir/native-layout.ld"
printf 'pub const floating = %s;\npub const compiled = %s;\npub const sqlite = %s;\npub const qualification = %s;\npub const sdmmc = %s;\npub const sdmmc_profile: u32 = %s;\npub const storage = %s;\npub const storage_service = %s;\npub const high_sram = %s;\npub const broker = %s;\npub const cold_flash = %s;\npub const sd_removal = %s;\npub const cold_capture = %s;\n' "$floating" "$compiled" "$sqlite" "$qualification" "$sdmmc" "$sdmmc_profile" "$storage" "$storage_service" "$high_sram" "$broker" "$cold_flash" "$sd_removal" "$cold_capture" > "$build_dir/native_options.next"
printf 'pub const fatfs_native = %s;\n' "$fatfs_native" >> "$build_dir/native_options.next"
printf 'pub const fatfs_sd = %s;\n' "$fatfs_sd" >> "$build_dir/native_options.next"
printf 'pub const fatfs_sd_direct = %s;\n' "$fatfs_sd_direct" >> "$build_dir/native_options.next"
if cmp -s "$build_dir/native_options.next" "$build_dir/native_options.zig"; then
    rm "$build_dir/native_options.next"
else
    mv "$build_dir/native_options.next" "$build_dir/native_options.zig"
fi
"$zig" cc -c -target riscv32-freestanding-none -mcpu="$cpu" -mabi="$abi" \
    -O2 -std=c11 -Wall -Wextra -Wconversion -Werror -ffreestanding \
    -I "$repo_root/include" -o "$build_dir/c_allocator.o" "$repo_root/probes/allocator/c_probe.c"
set -- "$build_dir/c_allocator.o"
if [ "$broker" = true ]; then
    python3 "$repo_root/tools/generate_memory_profile.py" --check
    broker_bitcode=-fno-emit-llvm-bc
    if [ "$fatfs_native" = true ]; then broker_bitcode="-femit-llvm-bc=$build_dir/fatfs-runtime.bc"; fi
    "$zig" build-obj -target riscv32-freestanding-none -mcpu="$cpu" -O safe -fllvm -fno-strip \
        -fno-stack-check -fno-stack-protector -fno-unwind-tables \
        --dep native_options --dep storage_vfs --dep task_calls --dep timer_group \
        -Mroot="$repo_root/src/platform/native/broker_runtime.zig" \
        -Mnative_options="$build_dir/native_options.zig" \
        -target riscv32-freestanding-none -mcpu="$cpu" -O safe \
        -Mstorage_vfs="$repo_root/src/storage_vfs.zig" \
        -target riscv32-freestanding-none -mcpu="$cpu" -O safe --dep task_control \
        -Mtask_calls="$repo_root/src/arch/riscv32/task_calls.zig" \
        -target riscv32-freestanding-none -mcpu="$cpu" -O safe \
        -Mtask_control="$repo_root/src/kernel/task_control.zig" \
        -target riscv32-freestanding-none -mcpu="$cpu" -O safe \
        -Mtimer_group="$repo_root/src/soc/esp32p4/timer_group.zig" \
        -femit-bin="$build_dir/sql_broker_runtime.o" "$broker_bitcode"
    if [ "$fatfs_native" = true ]; then
        # Preserve the Zig module's optimized LLVM IR/section attributes, emit
        # its final machine object with LLVM stack metadata. The final ELF
        # audit below enforces frame sizes; this is not a call-stack proof.
        "$zig" clang -cc1 -x ir -triple riscv32-unknown-none -target-abi "$abi" \
            -emit-obj -O2 -Wno-override-module -Werror -fstack-size-section \
            "$build_dir/fatfs-runtime.bc" -o "$build_dir/sql_broker_runtime.o"
    fi
    set -- "$@" "$build_dir/sql_broker_runtime.o"
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
        -I "$idf_path/components/esp_rom/include" -I "$idf_path/components/esp_rom/esp32p4/include" \
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
        for name in lfs lfs_util lfs_reader storage_api; do
            source="$littlefs_source/$name.c"
            if [ "$name" = lfs_reader ]; then source="$repo_root/probes/storage/littlefs_ro.c"; fi
            if [ "$name" = storage_api ]; then source="$repo_root/src/services/storage_littlefs.c"; fi
            "$zig" cc -c -target riscv32-freestanding-none -mcpu="$cpu" -mabi="$abi" \
                -Oz -std=c11 -ffreestanding -fno-builtin -fno-pic -ffunction-sections -fdata-sections \
                -fno-stack-protector -fno-unwind-tables -fno-asynchronous-unwind-tables -fstack-size-section \
                -isystem "$headers/riscv32-linux-musl" -isystem "$headers/generic-musl" \
                -isystem "$headers/riscv-linux-any" -I "$littlefs_source" -I "$repo_root/include" -I "$repo_root/src/services" \
                -DLFS_READONLY -DLFS_NO_MALLOC -DLFS_NO_ASSERT -DLFS_NO_DEBUG -DLFS_NO_WARN -DLFS_NO_ERROR \
                "$source" -o "$build_dir/sql_$name.o"
            set -- "$@" "$build_dir/sql_$name.o"
        done
        if [ "$storage_service" = true ] && [ "$fatfs_native" != true ]; then
            "$zig" build-obj -target riscv32-freestanding-none -mcpu="$cpu" -O safe -fllvm -fno-strip \
                -fno-stack-check -fno-stack-protector -fno-unwind-tables \
                --dep native_options --dep task_calls --dep timer_group --dep storage_rpc --dep spsc_ring \
                -Mroot="$repo_root/src/platform/native/storage_runtime.zig" \
                -Mnative_options="$build_dir/native_options.zig" \
                -target riscv32-freestanding-none -mcpu="$cpu" -O safe --dep task_control \
                -Mtask_calls="$repo_root/src/arch/riscv32/task_calls.zig" \
                -target riscv32-freestanding-none -mcpu="$cpu" -O safe \
                -Mtask_control="$repo_root/src/kernel/task_control.zig" \
                -target riscv32-freestanding-none -mcpu="$cpu" -O safe \
                -Mtimer_group="$repo_root/src/soc/esp32p4/timer_group.zig" \
                -target riscv32-freestanding-none -mcpu="$cpu" -O safe \
                -Mstorage_rpc="$repo_root/src/kernel/storage_rpc.zig" \
                -target riscv32-freestanding-none -mcpu="$cpu" -O safe \
                -Mspsc_ring="$repo_root/src/kernel/spsc_ring.zig" \
                -femit-bin="$build_dir/sql_storage_runtime.o"
            set -- "$@" "$build_dir/sql_storage_runtime.o"
        fi
        if [ "$fatfs_native" = true ]; then
            fixture_manifest=$(python3 "$repo_root/tools/build-fatfs-native-input.py" "$build_dir")
            cp "$fixture_manifest" "$build_dir/fatfs-fixture-manifest.json"
            fatfs_source=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["source_directory"])' "$fixture_manifest")
            fixture_include=$(dirname "$fixture_manifest")
            fatfs_units="guard unicode backend disk fixture fixture_disk"
            if [ "$fatfs_sd" = true ]; then fatfs_units="$fatfs_units volume native_disk card"; fi
            for name in $fatfs_units; do
                case "$name" in
                    guard) source="$repo_root/probes/fatfs-disk/safety.c" ;;
                    unicode) source="$fatfs_source/ffunicode.c" ;;
                    backend) source="$repo_root/src/storage/fatfs_backend.c" ;;
                    disk) source="$repo_root/src/storage/fatfs_disk.c" ;;
                    fixture) source="$repo_root/src/platform/native/fatfs_fixture.c" ;;
                    fixture_disk) source="$repo_root/src/platform/native/fatfs_fixture_disk.c" ;;
                    volume) source="$repo_root/src/storage/fatfs_volume.c" ;;
                    native_disk) source="$repo_root/src/platform/native/fatfs_disk.c" ;;
                    card) source="$repo_root/src/platform/native/fatfs_card.c" ;;
                esac
                "$zig" cc -c -target riscv32-freestanding-none -mcpu="$cpu" -mabi="$abi" \
                    -Oz -fno-inline-functions -std=c11 -ffreestanding -fno-builtin -fno-pic -ffunction-sections -fdata-sections \
                    -fno-stack-protector -fno-unwind-tables -fno-asynchronous-unwind-tables -fstack-size-section \
                    -isystem "$headers/riscv32-linux-musl" -isystem "$headers/generic-musl" -isystem "$headers/riscv-linux-any" \
                    -I "$repo_root/include" -I "$repo_root/probes/fatfs-disk" -I "$fatfs_source" -I "$fixture_include" \
                    -Dnih_ro_open=nih_fatfs_guard_open -Dnih_ro_directory=nih_fatfs_guard_directory -Dnih_ro_status_name=nih_fatfs_guard_status_name \
                    "$source" -o "$build_dir/sql_fat_$name.o"
                set -- "$@" "$build_dir/sql_fat_$name.o"
            done
        fi
        python3 "$repo_root/tools/native-sqlite-manifest.py" "$build_dir" "$source_dir" "$littlefs_source"
    else
        python3 "$repo_root/tools/native-sqlite-manifest.py" "$build_dir" "$source_dir"
    fi
fi
"$zig" build-exe -target riscv32-freestanding-none \
    -mcpu="$cpu" -O safe -fllvm -fno-strip \
    -fno-stack-check -fno-stack-protector -fno-unwind-tables \
    -fentry=nih_native_start -T "$build_dir/native-layout.ld" \
    -DNIH_NATIVE_REV3="$rev3" -DNIH_NATIVE_FLOATING="$fp_asm" --gc-sections \
    -I "$repo_root/src/arch/riscv32" -I "$repo_root/src/kernel" \
    "$repo_root/src/platform/native/start.S" "$@" \
    -target riscv32-freestanding-none -mcpu="$cpu" -O safe \
    --dep native_options --dep reset_capture --dep timer_group --dep native_tasks --dep psram --dep psram_supply --dep psram_mapping --dep record_log --dep sdmmc --dep storage_io --dep block_reader --dep storage_rpc --dep spsc_ring -Mroot="$repo_root/src/platform/native/main.zig" \
    -target riscv32-freestanding-none -mcpu="$cpu" -O safe \
    -Mreset_capture="$repo_root/src/soc/esp32p4/reset_capture.zig" \
    -target riscv32-freestanding-none -mcpu="$cpu" -O safe \
    -Mstorage_rpc="$repo_root/src/kernel/storage_rpc.zig" \
    -target riscv32-freestanding-none -mcpu="$cpu" -O safe \
    -Mblock_reader="$repo_root/src/storage/block.zig" \
    -target riscv32-freestanding-none -mcpu="$cpu" -O safe \
    -Msdmmc="$repo_root/src/soc/esp32p4/sdmmc.zig" \
    -target riscv32-freestanding-none -mcpu="$cpu" -O safe \
    -Mstorage_io="$repo_root/src/fs/sdmmc_owner.zig" \
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
    --dep core_arena --dep buddy_heap --dep task_resources --dep native_options --dep page_pool -Mnative_memory="$repo_root/src/platform/native/memory.zig" \
    -target riscv32-freestanding-none -mcpu="$cpu" -O safe \
    -Mpage_pool="$repo_root/src/kernel/page_pool.zig" \
    -target riscv32-freestanding-none -mcpu="$cpu" -O safe \
    -Mcore_arena="$repo_root/src/kernel/core_arena.zig" \
    -target riscv32-freestanding-none -mcpu="$cpu" -O safe \
    -Mbuddy_heap="$repo_root/src/kernel/buddy_heap.zig" \
    -target riscv32-freestanding-none -mcpu="$cpu" -O safe \
    -Mtask_resources="$repo_root/src/kernel/task_resources.zig" \
    -target riscv32-freestanding-none -mcpu="$cpu" -O safe \
    -Mpsram="$repo_root/src/soc/esp32p4/psram.zig" \
    -target riscv32-freestanding-none -mcpu="$cpu" -O safe \
    -Mpsram_supply="$repo_root/src/soc/esp32p4/psram_supply.zig" \
    -target riscv32-freestanding-none -mcpu="$cpu" -O safe \
    -Mpsram_mapping="$repo_root/src/soc/esp32p4/psram_mapping.zig" \
    -femit-bin="$build_dir/nihos-native.elf"

if [ "$fatfs_native" = true ]; then
    python3 - "$repo_root" "$build_dir" <<'PY_AUDIT'
import json
from pathlib import Path
import runpy
import sys
root, directory = map(Path, sys.argv[1:])
sys.path.insert(0, str(root / 'tools'))
audit = runpy.run_path(str(root / 'tools/check-native-image.py'))['audit']
report = audit((directory / 'nihos-native.elf').read_bytes(), None, 'sqlite', 'device',
               json.loads((directory / 'sqlite-manifest.json').read_text()))
(directory / 'fatfs-link-audit.json').write_text(json.dumps(report, indent=2) + '\n')
print('Native fixture ELF/frame audit passed; physical task stacks remain unqualified')
PY_AUDIT
fi
