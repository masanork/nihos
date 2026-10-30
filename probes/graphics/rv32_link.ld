/* ISA experiment only, not the ESP32-P4 Flash/MMU/partition layout. */
OUTPUT_ARCH(riscv)
ENTRY(graphics_font_link_probe)
MEMORY {
    code (rx) : ORIGIN = 0x41000000, LENGTH = 2M
    data (rw) : ORIGIN = 0x51000000, LENGTH = 1M
}
SECTIONS {
    .text : ALIGN(16) { *(.text .text.*) } > code
    .rodata : ALIGN(16) { *(.rodata .rodata.* .srodata .srodata.*) } > code
    .data : ALIGN(16) { __global_pointer$ = . + 0x800; *(.data .data.* .sdata .sdata.*) } > data
    .bss (NOLOAD) : ALIGN(64) { *(.bss .bss.* .sbss .sbss.*) *(COMMON) } > data
    .init_array : { KEEP(*(.init_array .init_array.*)) } > data
    /DISCARD/ : { *(.eh_frame .eh_frame_hdr .comment) }
    ASSERT(SIZEOF(.init_array) == 0, "unexpected C++ dynamic initializer")
}
