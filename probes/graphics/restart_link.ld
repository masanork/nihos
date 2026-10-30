/* Host RV32 ISA experiment. Whole library bank, separate persistent kernel bridge. */
OUTPUT_ARCH(riscv)
ENTRY(graphics_font_link_probe)
MEMORY {
    code (rx) : ORIGIN = 0x41000000, LENGTH = 2M
    library (rw) : ORIGIN = 0x51000000, LENGTH = 32K
    backing (rw) : ORIGIN = 0x51008000, LENGTH = 128K
}
SECTIONS {
    .text : ALIGN(16) { *(.text .text.*) } > code
    .rodata : ALIGN(16) { *(.rodata .rodata.* .srodata .srodata.*) } > code
    .backing.data : ALIGN(64) { *backing-rv32.o(.data .data.* .sdata .sdata.*) } > backing
    .backing.bss (NOLOAD) : ALIGN(64) { *backing-rv32.o(.bss .bss.* .sbss .sbss.* COMMON) } > backing
    .library.data : ALIGN(16) {
        __global_pointer$ = . + 0x800;
        *(.data .data.* .sdata .sdata.*)
    } > library
    .library.bss (NOLOAD) : ALIGN(64) { *(.bss .bss.* .sbss .sbss.* COMMON) } > library
    .init_array : { KEEP(*(.init_array .init_array.*)) } > library
    /DISCARD/ : { *(.eh_frame .eh_frame_hdr .comment) }
    ASSERT(SIZEOF(.init_array) == 0, "unexpected dynamic initializer")
    ASSERT(SIZEOF(.library.data) > 0 && SIZEOF(.library.bss) > 0, "missing library image")
    ASSERT(SIZEOF(.backing.bss) > 0, "kernel bridge not isolated")
}
