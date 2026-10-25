/*
 * Compile-checked native RV32 trap-entry prototype.
 *
 * This object is deliberately not linked into the ESP-IDF bring-up image and
 * no code installs it in mtvec yet. Interrupts remain disabled while the
 * dispatcher runs; per-core interrupt stacks and nesting come later.
 */

#include "context_offsets.inc"

    .section .text.nih_riscv_trap_entry, "ax", @progbits
    .balign 4
    .global nih_riscv_trap_entry
    .type nih_riscv_trap_entry, @function

/*
 * extern fn nih_riscv_trap_dispatch(
 *     interrupted: *IntegerContext,
 *     raw_mcause: u32,
 *     hart_id: u32,
 * ) callconv(.c) ?*IntegerContext;
 */
nih_riscv_trap_entry:
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

    /* Callee-saved registers carry return-state CSRs across dispatch. */
    csrr s10, mcause
    csrr s11, mstatus
    mv a0, sp
    mv a1, s10
    csrr a2, mhartid
    call nih_riscv_trap_dispatch
    beqz a0, .Linvalid_context

    mv sp, a0
    csrw mcause, s10
    csrw mstatus, s11
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

.Linvalid_context:
    wfi
    j .Linvalid_context

    .size nih_riscv_trap_entry, .-nih_riscv_trap_entry
