/* Synthetic ISA fixture. No P4 loader/MMU/Flash partition qualification. */
OUTPUT_ARCH(riscv)
ENTRY(graphics_worker_entry)
MEMORY {
    code (rx) : ORIGIN = 0x41000000, LENGTH = 2M
    data (rw) : ORIGIN = 0x51000000, LENGTH = 1M
    stacks (rw) : ORIGIN = 0x4ff60000, LENGTH = 96K
}
SECTIONS {
    .text : ALIGN(16) { *(.text .text.*) } > code
    .rodata : ALIGN(16) { *(.rodata .rodata.* .srodata .srodata.*) } > code
    .data : ALIGN(16) { __global_pointer$ = . + 0x800; *(.data .data.* .sdata .sdata.*) } > data
    .bss (NOLOAD) : ALIGN(64) { __bss_start = .; *(.bss .bss.* .sbss .sbss.*) *(COMMON) __bss_end = .; } > data
    .init_array : { KEEP(*(.init_array .init_array.*)) } > data
    .stacks (NOLOAD) : {
        __stacks_start = .;
        __stack0_bottom = .; . += 8192; __stack0_top = .;
        __stack1_bottom = .; . += 8192; __stack1_top = .;
        __irq_stack0_bottom = .; . += 8192; __irq_stack0_top = .;
        __irq_stack1_bottom = .; . += 8192; __irq_stack1_top = .;
        __peer_stack_bottom = .; . += 4096; __peer_stack_top = .;
        . = ALIGN(32768);
        __font_stack_bottom = .; . += 32768; __font_stack_top = .;
        __stacks_end = .;
    } > stacks
    /DISCARD/ : { *(.eh_frame .eh_frame_hdr .comment .flash.appdesc) }
    ASSERT(SIZEOF(.init_array) == 0, "unexpected C++ dynamic initializer")
    ASSERT(__font_stack_top - __font_stack_bottom == 32768, "font stack capacity")
}
