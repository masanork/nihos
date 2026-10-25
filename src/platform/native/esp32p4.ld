/* Internal SRAM only. Keep clear of the bootloader and CPU1 ROM stack.
 * Layout reference: ESP-IDF v5.4.4 ESP32-P4 memory.ld / bootloader.ld.
 */
OUTPUT_ARCH(riscv)
ENTRY(nih_native_start)
MEMORY {
    ram (rwx) : ORIGIN = 0x4ff00000, LENGTH = 128K
    descriptor (r) : ORIGIN = 0x40000020, LENGTH = 256
    compatibility (r) : ORIGIN = 0x40010020, LENGTH = 4
}
SECTIONS
{
    .flash.appdesc : { KEEP(*(.flash.appdesc)) } > descriptor
    /* The stock P4 second-stage loader requires two mapped segments.
     * Neither contains executable native code or runtime data. */
    .flash.rodata : { LONG(0x4e494853) } > compatibility
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
    ASSERT(__irq_stack1_top <= ORIGIN(ram) + LENGTH(ram), "native SRAM overflow")
    ASSERT(__heap_end - __heap_start >= 16384, "native SRAM heap below 16 KiB")
}
/* ROM ABI, not linked ESP-IDF implementations. */
PROVIDE(nih_rom_putc = 0x4fc00054);
PROVIDE(nih_rom_set_cpu1_entry = 0x4fc000a8);
