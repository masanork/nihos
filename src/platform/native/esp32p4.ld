/* Preprocessed by build-native-elf.sh. ESP-IDF v5.4.4 memory.ld.in uses
 * a low bank on rev1/2 and skips the first 128 KiB cache bank on rev3.
 * Keep the 160 KiB primary region below live loader/ROM allocations.
 * Stacks use a separate RW span supported by both revision layouts.
 */
#if NIH_NATIVE_REV3
__native_profile = 1;
#define NIH_SRAM_ORIGIN 0x4ff20000
#else
__native_profile = 0;
#define NIH_SRAM_ORIGIN 0x4ff00000
#endif
__native_devices = NIH_NATIVE_DEVICES;
__native_network = NIH_NATIVE_NETWORK;
OUTPUT_ARCH(riscv)
ENTRY(nih_native_start)
MEMORY {
    ram (rwx) : ORIGIN = NIH_SRAM_ORIGIN, LENGTH = 160K
    stack_ram (rw) : ORIGIN = 0x4ff60000, LENGTH = 56K
    descriptor (r) : ORIGIN = 0x40000020, LENGTH = 256
    flash_boot (rx) : ORIGIN = 0x40000120, LENGTH = 64K - 0x120
#if NIH_NATIVE_SQLITE
    flash_sql (rx) : ORIGIN = 0x40020000, LENGTH = 640K
#endif
#if NIH_NATIVE_KEYPAD
    flash_ui (r) : ORIGIN = 0x40020000, LENGTH = 640K
#endif
    flash_records (r) : ORIGIN = 0x40010020, LENGTH = 64K - 0x20
}
SECTIONS
{
    .flash.appdesc : { KEEP(*(.flash.appdesc)) } > descriptor
    .flash.boot : {
        __flash_boot_start = .;
        *(.flash.text.boot)
        __flash_boot_end = .;
    } > flash_boot
#if NIH_NATIVE_CARD_READ
    .flash.card : ALIGN(16) {
        __flash_card_start = .;
        *(.flash.text.card)
        __flash_card_end = .;
    } > flash_boot
#endif
#if NIH_NATIVE_DEVICES
    .flash.devices : ALIGN(16) {
        __flash_devices_start = .;
        *audio_tx.o(.text .text.*)
        *microphone_rx.o(.text .text.*)
        *rs485_uart.o(.text .text.*)
        *(.flash.text.devices)
        __flash_devices_end = .;
    } > flash_boot
#endif
#if NIH_NATIVE_NETWORK
    .flash.time : ALIGN(16) {
        __flash_time_start = .;
        *(.flash.text.time)
        __flash_time_end = .;
    } > flash_boot
#endif
    /* The stock P4 loader maps both segments before entering SRAM.
     * Only self-contained normal diagnostic tables use the second page. */
    .flash.rodata : {
        __flash_records_start = .;
        KEEP(*(.flash.rodata.records))
        *(.flash.rodata.boot_graphics)
        . = ALIGN(16);
        __card_boot_masks_start = .;
        *(.flash.rodata.card_boot.mask)
        __card_boot_masks_end = .;
        *(.flash.rodata.card_boot.meta)
        *(.flash.rodata.display)
        *(.flash.rodata.card_pin)
        *(.flash.rodata.bmi270)
        __flash_records_end = .;
    } > flash_records
#if NIH_NATIVE_KEYPAD
    .flash.uipad : ALIGN(4) {
        KEEP(*(.flash.keypad.pad))
        . = ORIGIN(flash_records) + LENGTH(flash_records);
    } > flash_records
    .flash.ui : ALIGN(64) {
        __flash_ui_start = .;
        __keypad_plan_start = .;
        *(.flash.keypad.plan)
        __keypad_plan_end = .;
        . = ALIGN(64);
        __keypad_atlas_start = .;
        *(.flash.keypad.atlas)
        __keypad_atlas_end = .;
        . = ALIGN(64);
        __keypad_font_start = .;
        *(.flash.keypad.font .flash.keypad.auto_font)
        __keypad_font_end = .;
#if NIH_NATIVE_PHOTO
        . = ALIGN(64);
#endif
        __flash_ui_end = .;
    } > flash_ui
#if NIH_NATIVE_PHOTO
    .flash.photo : ALIGN(64) {
        __photo_text_start = .;
        *photo_*.o(.text .text.*)
        *card_crypto*.o(.text .text.*)
        *(.flash.photo)
        *(.text.compiler_rt.addf3.* .text.compiler_rt.mulf3.* .text.compiler_rt.divf3.* .text.compiler_rt.divsf3.* .text.compiler_rt.divdf3.* .text.compiler_rt.comparef.* .text.compiler_rt.float_from_int.* .text.compiler_rt.int_from_float.* .text.compiler_rt.extendf.* .text.compiler_rt.truncf.*)
        . = ALIGN(64);
        __photo_text_end = .;
    } > flash_ui
    .flash.photo.rodata : ALIGN(64) {
        __photo_rodata_start = .;
        *photo_*.o(.rodata .rodata.* .srodata .srodata.*)
        *card_crypto*.o(.rodata .rodata.* .srodata .srodata.*)
        . = ALIGN(64);
        __photo_fixture_start = .;
        *(.flash.photo.fixture)
        __photo_fixture_end = .;
        . = ALIGN(4);
        __license_jis_start = .;
        *(.flash.license.data)
        __license_jis_end = .;
        . = ALIGN(4);
        __license_trust_start = .;
        *(.flash.license.trust)
        __license_trust_end = .;
        __photo_rodata_end = .;
    } > flash_ui
    .stack_sizes 0 : { KEEP(*(.stack_sizes)) }
#endif
#endif
#if NIH_NATIVE_SQLITE
    /* The stock P4 loader accepts exactly two mapped segments. Fill the gap
     * so esptool can merge records + SQLite into its second contiguous span. */
    .flash.sqlpad : ALIGN(4) {
        __flash_sql_pad_start = .;
        BYTE(0)
        . = ORIGIN(flash_records) + LENGTH(flash_records);
        __flash_sql_pad_end = .;
    } > flash_records
    .flash.sqltext : {
        __flash_sql_text_start = .;
        *sql_sqlite3.o(.text .text.*)
        *sql_session.o(.text .text.*)
        *sql_vfs.o(.text .text.*)
        *sql_lfs.o(.text .text.*)
        *sql_lfs_util.o(.text .text.*)
        *sql_lfs_reader.o(.text .text.*)
        . = ALIGN(16);
        __flash_sql_text_end = .;
    } > flash_sql
    .flash.sqlrodata : ALIGN(16) {
        __flash_sql_rodata_start = .;
        *sql_sqlite3.o(.rodata .rodata.* .srodata .srodata.*)
        *sql_session.o(.rodata .rodata.* .srodata .srodata.*)
        *sql_vfs.o(.rodata .rodata.* .srodata .srodata.*)
        *sql_lfs.o(.rodata .rodata.* .srodata .srodata.*)
        *sql_lfs_util.o(.rodata .rodata.* .srodata .srodata.*)
        *sql_lfs_reader.o(.rodata .rodata.* .srodata .srodata.*)
        __flash_sql_rodata_end = .;
    } > flash_sql
#endif
    .text : ALIGN(64) { KEEP(*(.text.start)) *(.text .text.* .iram1 .iram1.*) } > ram
    .fp_app : ALIGN(16) {
        __fp_app_start = .;
        *(.fp_app .fp_app.*)
        __fp_app_end = .;
    } > ram
    .rodata : ALIGN(16) { *(.rodata .rodata.* .srodata .srodata.*) } > ram
    .data : ALIGN(16) {
        __global_pointer$ = . + 0x800;
        *(.data .data.* .sdata .sdata.*)
    } > ram
    .bss (NOLOAD) : ALIGN(16) {
        __bss_start = .;
        *(.bss .bss.* .sbss .sbss.*) *(COMMON)
        . = ALIGN(16);
        __bss_end = .;
    } > ram
    .stacks (NOLOAD) : ALIGN(16) {
        __stacks_start = .;
        __stack0_bottom = .; . += 8192; __stack0_top = .;
        __stack1_bottom = .; . += 8192; __stack1_top = .;
        __irq_stack0_bottom = .; . += 8192; __irq_stack0_top = .;
        __irq_stack1_bottom = .; . += 8192; __irq_stack1_top = .;
        __task_stacks_start = .;
        KEEP(*(.native.task_stacks))
        __task_stacks_end = .;
        __stacks_end = .;
    } > stack_ram
    .heap (NOLOAD) : ALIGN(64) {
        __heap_start = .;
        . = ORIGIN(ram) + LENGTH(ram);
        __heap_end = .;
    } > ram
    /* Free service SRAM belongs to the base, not to a card application.
     * The SDK/loader-supported high RW window starts at 0x4ff40000.
     * Retain the top 4 KiB guard used by the high-SRAM qualification. */
    __service_sram0_start = MAX(ORIGIN(ram) + LENGTH(ram), 0x4ff40000);
    __service_sram0_end = ORIGIN(stack_ram);
#if NIH_NATIVE_GRAPHICS
    __service_sram1_start = ORIGIN(graphics_ram) + LENGTH(graphics_ram);
#else
    __service_sram1_start = ORIGIN(stack_ram) + LENGTH(stack_ram);
#endif
    __service_sram1_end = 0x4ff9f000;
    ASSERT(__service_sram0_start < __service_sram0_end, "no low service SRAM")
    ASSERT(__service_sram1_start < __service_sram1_end, "no high service SRAM")
    /DISCARD/ : { *(.eh_frame .eh_frame_hdr .comment .riscv.attributes) }
    ASSERT(SIZEOF(.flash.appdesc) == 256, "invalid app descriptor")
    ASSERT(SIZEOF(.flash.boot) > 0, "missing Flash boot code")
    ASSERT(SIZEOF(.flash.boot) <= 65248, "boot code exceeds first Flash page")
    ASSERT(SIZEOF(.flash.rodata) > 0, "missing mapped record tables")
    ASSERT(SIZEOF(.flash.rodata) <= 65504, "record tables exceed one Flash page")
    ASSERT(__stacks_start == ORIGIN(stack_ram), "wrong stack region origin")
    ASSERT(ORIGIN(ram) + LENGTH(ram) <= ORIGIN(stack_ram), "primary and stack SRAM overlap")
    ASSERT(__task_stacks_end - __task_stacks_start == 24576, "invalid worker stack reservation")
    ASSERT(__stacks_end == ORIGIN(stack_ram) + LENGTH(stack_ram), "invalid stack region size")
    ASSERT(__heap_end - __heap_start >= 49152, "native SRAM heap below 48 KiB")
}
/* ROM ABI, not linked ESP-IDF implementations. */
/* Keep the audited ROM ABI visible even when bounded live-console TX replaces
 * all ROM putc calls in this image. This does not link or execute ROM code. */
nih_rom_putc = 0x4fc00054;
nih_rom_get_cpu_ticks = 0x4fc00040;
nih_rom_set_cpu_ticks = 0x4fc00044;
PROVIDE(nih_rom_set_cpu1_entry = 0x4fc000a8);
PROVIDE(nih_rom_l2_line_size = 0x4fc003cc);
PROVIDE(nih_rom_l2_enable = 0x4fc00504);
PROVIDE(nih_rom_cache_invalidate = 0x4fc003e4);
PROVIDE(nih_rom_cache_writeback = 0x4fc003f4);
