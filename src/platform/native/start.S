/* No ESP-IDF runtime: own stacks, gp, BSS, vectors and machine entry. */
#include "context_offsets.inc"
#include "task_call_numbers.inc"
    .global nih_native_task_context_bytes
    .set nih_native_task_context_bytes, NIH_CTX_SIZE
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
#if NIH_NATIVE_DISPLAY_SCANOUT
    /* New boot owns the device, CPU1 is parked, no native services exist.
     * USB reset can retain a previous scanout DMA. Retire it BEFORE clearing
     * SRAM or remapping PSRAM; it must not use old descriptors during CRT.
     * Offsets are statically checked against the vendor LL struct in C. */
    li t0, 0x500e60c0
    lw t1, 0(t0)
    li t2, (1 << 21)
    or t1, t1, t2
    sw t1, 0(t0)
    fence iorw, iorw
    not t2, t2
    and t1, t1, t2
    sw t1, 0(t0)
    li t0, 0x500e6014
    lw t1, 0(t0)
    li t2, ~(1 << 13)
    and t1, t1, t2
    sw t1, 0(t0)
    li t0, 0x500e6018
    lw t1, 0(t0)
    li t2, ~(1 << 5)
    and t1, t1, t2
    sw t1, 0(t0)
    fence iorw, iorw
#endif
    .option push
    .option norelax
    la gp, __global_pointer$
    .option pop
    /* No C frame exists yet. Clear the separate NOLOAD stack span before
     * selecting our own stack; CPU1 is still parked in ROM. */
    la t0, __stacks_start
    la t1, __stacks_end
.Lzero_stacks:
    bgeu t0, t1, .Lstacks_ready
    sw zero, 0(t0)
    addi t0, t0, 4
    j .Lzero_stacks
.Lstacks_ready:
    la sp, __stack0_top
    la t0, __bss_start
    la t1, __bss_end
1:  bgeu t0, t1, 2f
    sw zero, 0(t0)
    addi t0, t0, 4
    j 1b
2:
#if NIH_NATIVE_GRAPHICS
    la t0, __graphics_bss_start
    la t1, __graphics_bss_end
.Lzero_graphics_bss:
    bgeu t0, t1, .Lgraphics_bss_ready
    sw zero, 0(t0)
    addi t0, t0, 4
    j .Lzero_graphics_bss
.Lgraphics_bss_ready:
#endif
    call .Lsetup_vector
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
    li t0, 0x6000
    csrc mstatus, t0
    /* Pinned P4 MEXSTATUS.WFFEN: use interrupt wait, not event wait. */
    csrci 0x7e1, 16
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
    .type nih_native_trap, @function
nih_native_trap:
    /* Stable integer frame; an opted-in FP bank is stored separately. */
    addi sp, sp, -NIH_CTX_SIZE
    sw ra, NIH_CTX_RA(sp)
    sw gp, NIH_CTX_GP(sp)
    sw tp, NIH_CTX_TP(sp)
    sw t0, NIH_CTX_T0(sp)
    sw t1, NIH_CTX_T1(sp)
    sw t2, NIH_CTX_T2(sp)
    sw s0, NIH_CTX_S0(sp)
    sw s1, NIH_CTX_S1(sp)
    sw a0, NIH_CTX_A0(sp)
    sw a1, NIH_CTX_A1(sp)
    sw a2, NIH_CTX_A2(sp)
    sw a3, NIH_CTX_A3(sp)
    sw a4, NIH_CTX_A4(sp)
    sw a5, NIH_CTX_A5(sp)
    sw a6, NIH_CTX_A6(sp)
    sw a7, NIH_CTX_A7(sp)
    sw s2, NIH_CTX_S2(sp)
    sw s3, NIH_CTX_S3(sp)
    sw s4, NIH_CTX_S4(sp)
    sw s5, NIH_CTX_S5(sp)
    sw s6, NIH_CTX_S6(sp)
    sw s7, NIH_CTX_S7(sp)
    sw s8, NIH_CTX_S8(sp)
    sw s9, NIH_CTX_S9(sp)
    sw s10, NIH_CTX_S10(sp)
    sw s11, NIH_CTX_S11(sp)
    sw t3, NIH_CTX_T3(sp)
    sw t4, NIH_CTX_T4(sp)
    sw t5, NIH_CTX_T5(sp)
    sw t6, NIH_CTX_T6(sp)
    addi t0, sp, NIH_CTX_SIZE
    sw t0, NIH_CTX_SP(sp)
    csrr t0, mepc
    sw t0, NIH_CTX_MEPC(sp)

    mv s3, sp
    csrr s0, mhartid
    csrr s1, mcause
    csrr s2, mstatus
    li t0, 2
    bgeu s0, t0, .Lhalt
    la t0, .Lirq_tops
    slli t1, s0, 2
    add t0, t0, t1
    lw sp, 0(t0)
#if NIH_NATIVE_FLOATING
    la t0, nih_native_fp_current
    add t0, t0, t1
    lw a0, 0(t0)
    beqz a0, .Lno_fp_save
    li t0, 0x6000
    csrs mstatus, t0
    call nih_riscv_fpu_save
    la t0, nih_native_fp_saves
    slli t1, s0, 2
    add t0, t0, t1
    lw t1, 0(t0)
    addi t1, t1, 1
    sw t1, 0(t0)
.Lno_fp_save:
#endif
    li t0, 0x6000
    csrc mstatus, t0
    mv a0, s3
    mv a1, s1
    mv a2, s0
    mv a3, s2
    /* No nesting: policy/frame mutations run only on this private stack. */
    call nih_native_dispatch
    beqz a0, .Lhalt
    mv s3, a0
#if NIH_NATIVE_FLOATING
    la t0, nih_native_fp_selected
    slli t1, s0, 2
    add t0, t0, t1
    lw s4, 0(t0)
    beqz s4, .Lno_fp_restore
    li t0, 0x6000
    csrs mstatus, t0
    mv a0, s4
    call nih_riscv_fpu_restore
    la t0, nih_native_fp_restores
    slli t1, s0, 2
    add t0, t0, t1
    lw t1, 0(t0)
    addi t1, t1, 1
    sw t1, 0(t0)
.Lno_fp_restore:
    la t0, nih_native_fp_current
    slli t1, s0, 2
    add t0, t0, t1
    sw s4, 0(t0)
#endif
    mv sp, s3
    csrr t1, mhartid
    slli t1, t1, 3
    la t0, nih_native_return_states
    add t0, t0, t1
    lw t1, 4(t0)
    csrw mcause, t1
    lw t1, 0(t0)
    andi t1, t1, -9
    csrw mstatus, t1
    lw t0, NIH_CTX_MEPC(sp)
    csrw mepc, t0
    lw ra, NIH_CTX_RA(sp)
    lw gp, NIH_CTX_GP(sp)
    lw tp, NIH_CTX_TP(sp)
    lw t0, NIH_CTX_T0(sp)
    lw t1, NIH_CTX_T1(sp)
    lw t2, NIH_CTX_T2(sp)
    lw s0, NIH_CTX_S0(sp)
    lw s1, NIH_CTX_S1(sp)
    lw a0, NIH_CTX_A0(sp)
    lw a1, NIH_CTX_A1(sp)
    lw a2, NIH_CTX_A2(sp)
    lw a3, NIH_CTX_A3(sp)
    lw a4, NIH_CTX_A4(sp)
    lw a5, NIH_CTX_A5(sp)
    lw a6, NIH_CTX_A6(sp)
    lw a7, NIH_CTX_A7(sp)
    lw s2, NIH_CTX_S2(sp)
    lw s3, NIH_CTX_S3(sp)
    lw s4, NIH_CTX_S4(sp)
    lw s5, NIH_CTX_S5(sp)
    lw s6, NIH_CTX_S6(sp)
    lw s7, NIH_CTX_S7(sp)
    lw s8, NIH_CTX_S8(sp)
    lw s9, NIH_CTX_S9(sp)
    lw s10, NIH_CTX_S10(sp)
    lw s11, NIH_CTX_S11(sp)
    lw t3, NIH_CTX_T3(sp)
    lw t4, NIH_CTX_T4(sp)
    lw t5, NIH_CTX_T5(sp)
    lw t6, NIH_CTX_T6(sp)
    addi sp, sp, NIH_CTX_SIZE
    mret
    .size nih_native_trap, .-nih_native_trap

    .global nih_native_task_trampoline
nih_native_task_trampoline:
    mv t0, a0
    mv a0, a1
    jalr t0
    j nih_riscv_task_exit

    .global nih_riscv_task_call
    .type nih_riscv_task_call, @function
nih_riscv_task_call:
    mv a7, a0
    mv a0, a1
    mv a1, a2
    ecall
    ret
    .size nih_riscv_task_call, .-nih_riscv_task_call

    .global nih_riscv_task_exit
nih_riscv_task_exit:
    li a7, NIH_TASK_EXIT
    li a1, 0
    ecall
    j .Lhalt

    .section .rodata.native_irq_tops, "a", @progbits
    .balign 4
.Lirq_tops:
    .long __irq_stack0_top, __irq_stack1_top
