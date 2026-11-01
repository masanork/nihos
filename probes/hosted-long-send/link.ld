/* Link-only SRAM window from the C6 fixture. No startup or boot descriptor. */
OUTPUT_ARCH(riscv)
ENTRY(nih_hosted_long_send_compile_probe)
EXTERN(nih_hosted_long_dma_layout nih_hosted_long_dma_prepare_probe nih_hosted_long_dma_finish_probe)
MEMORY { ram (rwx) : ORIGIN = 0x4ff00000, LENGTH = 128K }
SECTIONS {
    .text : ALIGN(64) { *(.text .text.*) } > ram
    .rodata : ALIGN(16) { *(.rodata .rodata.* .srodata .srodata.*) } > ram
    .data : ALIGN(64) { *(.data .data.* .sdata .sdata.*) } > ram
    .hosted_dma : ALIGN(64) { KEEP(*(.hosted_dma)) } > ram
    .bss (NOLOAD) : ALIGN(64) { *(.bss .bss.* .sbss .sbss.*) *(COMMON) } > ram
    /DISCARD/ : { *(.eh_frame .eh_frame_hdr .comment) }
}
PROVIDE(nih_rom_cache_invalidate = 0x4fc003e4);
PROVIDE(nih_rom_cache_writeback = 0x4fc003f4);
