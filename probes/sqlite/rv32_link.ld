/* Synthetic link-only windows. Not an ESP32-P4 memory/MMU map or boot image. */
OUTPUT_ARCH(riscv)
ENTRY(nih_sqlite_link_probe)
EXTERN(nih_sqlite_session_open nih_sqlite_session_eval nih_sqlite_session_close)
EXTERN(nih_sqlite_session_owner nih_sqlite_session_active nih_sqlite_session_cancel)
MEMORY {
    code (rx) : ORIGIN = 0x41000000, LENGTH = 2M
    data (rw) : ORIGIN = 0x51000000, LENGTH = 1M
}
SECTIONS {
    .text : ALIGN(16) { *(.text .text.*) } > code
    .rodata : ALIGN(16) { KEEP(*(.rodata.nih_sqlite_rv32_abi)) *(.rodata .rodata.* .srodata .srodata.*) } > code
    .data : ALIGN(16) { *(.data .data.* .sdata .sdata.*) } > data
    .bss (NOLOAD) : ALIGN(64) { *(.bss .bss.* .sbss .sbss.*) *(COMMON) } > data
    /DISCARD/ : { *(.eh_frame .eh_frame_hdr .comment) }
}
