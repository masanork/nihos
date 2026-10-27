/* Standalone CPU0 C6 probe, same SRAM/loader ABI as the native backend.
 * CPU1 stays parked. Every trap is fatal; no IRQ source is enabled. */
    .section .flash.appdesc, "a", @progbits
    .long 0xabcd5432, 0, 0, 0
    .asciz "c6-sdio-1"
    .zero 22
    .asciz "nihos-c6-probe"
    .zero 17
    .zero 16 + 16
    .asciz "ROM ABI v5.4.4"
    .zero 17
    .zero 32
    .short 0, 0xffff
    .byte 16
    .zero 3 + 72

    .section .text.start, "ax", @progbits
    .global nih_native_start
nih_native_start:
    csrci mstatus, 8
    li t0, 0x6000
    csrc mstatus, t0
    .option push
    .option norelax
    la gp, __global_pointer$
    .option pop
    la sp, __stack0_top
    la t0, __bss_start
    la t1, __bss_end
1:  bgeu t0, t1, 2f
    sw zero, 0(t0)
    addi t0, t0, 4
    j 1b
2:  la t0, nih_c6_trap
    ori t0, t0, 3
    csrw mtvec, t0
    li t0, 0x20800008
    sw zero, 0(t0)
    call nih_c6_main
3:  j 3b

    .balign 64
nih_c6_trap:
    csrci mstatus, 8
    csrr a0, mcause
    csrr a1, mepc
    csrr a2, mtval
    la sp, __irq_stack0_top
    call nih_c6_exception
    j 3b
