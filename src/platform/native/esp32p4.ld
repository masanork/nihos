/* Preprocessed by build-native-elf.sh. ESP-IDF v5.4.4 memory.ld.in uses
 * a low bank on rev1/2 and skips the first 128 KiB cache bank on rev3.
 * Keep the entire 160 KiB region below live loader/ROM allocations.
 */
#if NIH_NATIVE_REV3
__native_profile = 1;
#define NIH_SRAM_ORIGIN 0x4ff20000
#else
__native_profile = 0;
#define NIH_SRAM_ORIGIN 0x4ff00000
#endif
OUTPUT_ARCH(riscv)
ENTRY(nih_native_start)
MEMORY {
    ram (rwx) : ORIGIN = NIH_SRAM_ORIGIN, LENGTH = 160K
    descriptor (r) : ORIGIN = 0x40000020, LENGTH = 256
    flash_boot (rx) : ORIGIN = 0x40000120, LENGTH = 64K - 0x120
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
    /* The stock P4 loader maps both segments before entering SRAM.
     * Only self-contained normal diagnostic tables use the second page. */
    .flash.rodata : {
        __flash_records_start = .;
        KEEP(*(.flash.rodata.records))
        __flash_records_end = .;
    } > flash_records
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
        __stack0_bottom = .; . += 8192; __stack0_top = .;
        __stack1_bottom = .; . += 8192; __stack1_top = .;
        __irq_stack0_bottom = .; . += 8192; __irq_stack0_top = .;
        __irq_stack1_bottom = .; . += 8192; __irq_stack1_top = .;
    } > ram
    .heap (NOLOAD) : ALIGN(64) {
        __heap_start = .;
        . = ORIGIN(ram) + LENGTH(ram);
        __heap_end = .;
    } > ram
    /DISCARD/ : { *(.eh_frame .eh_frame_hdr .comment .riscv.attributes) }
    ASSERT(SIZEOF(.flash.appdesc) == 256, "invalid app descriptor")
    ASSERT(SIZEOF(.flash.boot) > 0, "missing Flash boot code")
    ASSERT(SIZEOF(.flash.boot) <= 65248, "boot code exceeds first Flash page")
    ASSERT(SIZEOF(.flash.rodata) > 0, "missing mapped record tables")
    ASSERT(SIZEOF(.flash.rodata) <= 65504, "record tables exceed one Flash page")
    ASSERT(__irq_stack1_top <= ORIGIN(ram) + LENGTH(ram), "native SRAM overflow")
    ASSERT(__heap_end - __heap_start >= 49152, "native SRAM heap below 48 KiB")
}
/* ROM ABI, not linked ESP-IDF implementations. */
PROVIDE(nih_rom_putc = 0x4fc00054);
PROVIDE(nih_rom_set_cpu1_entry = 0x4fc000a8);
PROVIDE(nih_rom_l2_line_size = 0x4fc003cc);
PROVIDE(nih_rom_l2_enable = 0x4fc00504);
PROVIDE(nih_rom_cache_invalidate = 0x4fc003e4);
PROVIDE(nih_rom_cache_writeback = 0x4fc003f4);
