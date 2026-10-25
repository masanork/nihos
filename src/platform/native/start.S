/* No ESP-IDF runtime: own stacks, gp, BSS, vectors and machine entry. */
    .section .flash.appdesc, "a", @progbits
    .long 0xabcd5432, 0, 0, 0
    .asciz "native-boot-1"
    .zero 18
    .asciz "nihos-native"
    .zero 19
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
2:  call .Lsetup_vector
    call nih_native_main
    j .Lhalt

    .global nih_native_cpu1_start
nih_native_cpu1_start:
    csrci mstatus, 8
    .option push
    .option norelax
    la gp, __global_pointer$
    .option pop
    la sp, __stack1_top
    call .Lsetup_vector
    call nih_native_cpu1_main
.Lhalt:
    csrci mstatus, 8
    j .Lhalt

.Lsetup_vector:
    la t0, nih_native_trap
    ori t0, t0, 3
    csrw mtvec, t0
#if NIH_NATIVE_REV3
    csrw 0x347, zero
#else
    li t0, 0x20800008
    sw zero, 0(t0)
    lw t0, 0(t0)
#endif
    /* No selective hardware vectoring; all enabled sources use mtvec. */
    ret

    .balign 64
    .global nih_native_trap
nih_native_trap:
    /* Integer-only kernel, non-nested traps on this hart's private stack. */
    addi sp, sp, -80
    sw ra, 0(sp)
    sw t0, 4(sp)
    sw t1, 8(sp)
    sw t2, 12(sp)
    sw a0, 16(sp)
    sw a1, 20(sp)
    sw a2, 24(sp)
    sw a3, 28(sp)
    sw a4, 32(sp)
    sw a5, 36(sp)
    sw a6, 40(sp)
    sw a7, 44(sp)
    sw t3, 48(sp)
    sw t4, 52(sp)
    sw t5, 56(sp)
    sw t6, 60(sp)
    csrr a0, mcause
    sw a0, 64(sp)
    csrr a1, mepc
    csrr a2, mhartid
    csrr t0, mstatus
    sw t0, 68(sp)
    call nih_native_dispatch
    csrw mepc, a0
    /* CLIC mret needs the active trap's mcause as well as mstatus. */
    lw t0, 64(sp)
    csrw mcause, t0
    lw t0, 68(sp)
    csrw mstatus, t0
    lw ra, 0(sp)
    lw t0, 4(sp)
    lw t1, 8(sp)
    lw t2, 12(sp)
    lw a0, 16(sp)
    lw a1, 20(sp)
    lw a2, 24(sp)
    lw a3, 28(sp)
    lw a4, 32(sp)
    lw a5, 36(sp)
    lw a6, 40(sp)
    lw a7, 44(sp)
    lw t3, 48(sp)
    lw t4, 52(sp)
    lw t5, 56(sp)
    lw t6, 60(sp)
    addi sp, sp, 80
    mret
