/*
 * RV32F context transfers and task-context probes.
 * Context ABI: a0 points to 32 raw f-register words followed by fcsr.
 * Restore deliberately replaces every FP register; only assembly calls it.
 */
#include "task_call_numbers.inc"
    .section .iram1.nih_riscv_fpu_save, "ax", @progbits
    .balign 4
    .global nih_riscv_fpu_save
    .type nih_riscv_fpu_save, @function
nih_riscv_fpu_save:
    fsw f0, 0(a0)
    fsw f1, 4(a0)
    fsw f2, 8(a0)
    fsw f3, 12(a0)
    fsw f4, 16(a0)
    fsw f5, 20(a0)
    fsw f6, 24(a0)
    fsw f7, 28(a0)
    fsw f8, 32(a0)
    fsw f9, 36(a0)
    fsw f10, 40(a0)
    fsw f11, 44(a0)
    fsw f12, 48(a0)
    fsw f13, 52(a0)
    fsw f14, 56(a0)
    fsw f15, 60(a0)
    fsw f16, 64(a0)
    fsw f17, 68(a0)
    fsw f18, 72(a0)
    fsw f19, 76(a0)
    fsw f20, 80(a0)
    fsw f21, 84(a0)
    fsw f22, 88(a0)
    fsw f23, 92(a0)
    fsw f24, 96(a0)
    fsw f25, 100(a0)
    fsw f26, 104(a0)
    fsw f27, 108(a0)
    fsw f28, 112(a0)
    fsw f29, 116(a0)
    fsw f30, 120(a0)
    fsw f31, 124(a0)
    csrr t0, fcsr
    sw t0, 128(a0)
    ret
    .size nih_riscv_fpu_save, .-nih_riscv_fpu_save

    .section .iram1.nih_riscv_fpu_restore, "ax", @progbits
    .balign 4
    .global nih_riscv_fpu_restore
    .type nih_riscv_fpu_restore, @function
nih_riscv_fpu_restore:
    flw f0, 0(a0)
    flw f1, 4(a0)
    flw f2, 8(a0)
    flw f3, 12(a0)
    flw f4, 16(a0)
    flw f5, 20(a0)
    flw f6, 24(a0)
    flw f7, 28(a0)
    flw f8, 32(a0)
    flw f9, 36(a0)
    flw f10, 40(a0)
    flw f11, 44(a0)
    flw f12, 48(a0)
    flw f13, 52(a0)
    flw f14, 56(a0)
    flw f15, 60(a0)
    flw f16, 64(a0)
    flw f17, 68(a0)
    flw f18, 72(a0)
    flw f19, 76(a0)
    flw f20, 80(a0)
    flw f21, 84(a0)
    flw f22, 88(a0)
    flw f23, 92(a0)
    flw f24, 96(a0)
    flw f25, 100(a0)
    flw f26, 104(a0)
    flw f27, 108(a0)
    flw f28, 112(a0)
    flw f29, 116(a0)
    flw f30, 120(a0)
    flw f31, 124(a0)
    lw t0, 128(a0)
    csrw fcsr, t0
    ret
    .size nih_riscv_fpu_restore, .-nih_riscv_fpu_restore

    /* C-ABI snapshot preserves both the physical bank and original mstatus,
     * including FS=Off. Called inside the interrupt-masked lease boundary.
     */
    .section .iram1.nih_riscv_fpu_snapshot, "ax", @progbits
    .balign 4
    .global nih_riscv_fpu_snapshot
    .type nih_riscv_fpu_snapshot, @function
nih_riscv_fpu_snapshot:
    addi sp, sp, -16
    sw ra, 12(sp)
    csrr t0, mstatus
    sw t0, 8(sp)
    csrci mstatus, 8
    li t0, 0x6000
    csrs mstatus, t0
    call nih_riscv_fpu_save
    lw t0, 8(sp)
    lw ra, 12(sp)
    addi sp, sp, 16
    csrw mstatus, t0
    ret
    .size nih_riscv_fpu_snapshot, .-nih_riscv_fpu_snapshot

    /*
     * Check the active bank against FloatingProbe without changing any FP
     * state or callee-saved integer registers. Layout: pattern, expected
     * fcsr, iterations, failed, stack_address.
     */
    .section .iram1.nih_riscv_fpu_task_check, "ax", @progbits
    .balign 4
    .global nih_riscv_fpu_task_check
    .type nih_riscv_fpu_task_check, @function
nih_riscv_fpu_task_check:
    lw t2, 0(a0)
.macro NIH_CHECK_FREG reg, index
    fmv.x.w t0, \reg
    addi t1, t2, \index
    bne t0, t1, .Ltask_check_failed
.endm
    NIH_CHECK_FREG f0, 0
    NIH_CHECK_FREG f1, 1
    NIH_CHECK_FREG f2, 2
    NIH_CHECK_FREG f3, 3
    NIH_CHECK_FREG f4, 4
    NIH_CHECK_FREG f5, 5
    NIH_CHECK_FREG f6, 6
    NIH_CHECK_FREG f7, 7
    NIH_CHECK_FREG f8, 8
    NIH_CHECK_FREG f9, 9
    NIH_CHECK_FREG f10, 10
    NIH_CHECK_FREG f11, 11
    NIH_CHECK_FREG f12, 12
    NIH_CHECK_FREG f13, 13
    NIH_CHECK_FREG f14, 14
    NIH_CHECK_FREG f15, 15
    NIH_CHECK_FREG f16, 16
    NIH_CHECK_FREG f17, 17
    NIH_CHECK_FREG f18, 18
    NIH_CHECK_FREG f19, 19
    NIH_CHECK_FREG f20, 20
    NIH_CHECK_FREG f21, 21
    NIH_CHECK_FREG f22, 22
    NIH_CHECK_FREG f23, 23
    NIH_CHECK_FREG f24, 24
    NIH_CHECK_FREG f25, 25
    NIH_CHECK_FREG f26, 26
    NIH_CHECK_FREG f27, 27
    NIH_CHECK_FREG f28, 28
    NIH_CHECK_FREG f29, 29
    NIH_CHECK_FREG f30, 30
.purgem NIH_CHECK_FREG
    fmv.x.w t0, f31
    li t1, 0x00800000
    add t1, t2, t1
    bne t0, t1, .Ltask_check_failed
    csrr t0, fcsr
    lw t1, 4(a0)
    bne t0, t1, .Ltask_check_failed
    lw t0, 8(a0)
    addi t0, t0, 1
    sw t0, 8(a0)
    li a0, 1
    ret
.Ltask_check_failed:
    li t0, 1
    sw t0, 12(a0)
    li a0, 0
    ret
    .size nih_riscv_fpu_task_check, .-nih_riscv_fpu_task_check

    /*
     * C ABI: (FloatingProbe *probe, int (*entry)(u32), u32 argument).
     * This task entry owns the entire FP bank and is never called as a normal
     * returning C function. Its callback must be explicitly integer-only;
     * the task's bank remains live across callback ECALLs and preemption.
     */
    .section .iram1.nih_riscv_fpu_task_probe, "ax", @progbits
    .balign 4
    .global nih_riscv_fpu_task_probe
    .type nih_riscv_fpu_task_probe, @function
nih_riscv_fpu_task_probe:
    addi sp, sp, -32
    sw s0, 0(sp)
    sw s1, 4(sp)
    sw s2, 8(sp)
    sw s3, 12(sp)
    sw s4, 16(sp)
    sw s5, 20(sp)
    sw ra, 24(sp)
    mv s0, a0
    mv s1, a1
    mv s2, a2
    lw s3, 0(s0)
    lw s4, 4(s0)

    /* Match the CPU0 probe: unique raw words plus inexact f31 arithmetic. */
    andi t0, s4, -32
    csrw fcsr, t0
.macro NIH_SEED_FREG reg, index
    addi t0, s3, \index
    fmv.w.x \reg, t0
.endm
    NIH_SEED_FREG f0, 0
    NIH_SEED_FREG f1, 1
    NIH_SEED_FREG f2, 2
    NIH_SEED_FREG f3, 3
    NIH_SEED_FREG f4, 4
    NIH_SEED_FREG f5, 5
    NIH_SEED_FREG f6, 6
    NIH_SEED_FREG f7, 7
    NIH_SEED_FREG f8, 8
    NIH_SEED_FREG f9, 9
    NIH_SEED_FREG f10, 10
    NIH_SEED_FREG f11, 11
    NIH_SEED_FREG f12, 12
    NIH_SEED_FREG f13, 13
    NIH_SEED_FREG f14, 14
    NIH_SEED_FREG f15, 15
    NIH_SEED_FREG f16, 16
    NIH_SEED_FREG f17, 17
    NIH_SEED_FREG f18, 18
    NIH_SEED_FREG f19, 19
    NIH_SEED_FREG f20, 20
    NIH_SEED_FREG f21, 21
    NIH_SEED_FREG f22, 22
    NIH_SEED_FREG f23, 23
    NIH_SEED_FREG f24, 24
    NIH_SEED_FREG f25, 25
    NIH_SEED_FREG f26, 26
    NIH_SEED_FREG f27, 27
    NIH_SEED_FREG f28, 28
    NIH_SEED_FREG f29, 29
    NIH_SEED_FREG f30, 30
.purgem NIH_SEED_FREG
    fadd.s f31, f0, f1, dyn

    mv a0, s2
    jalr ra, s1, 0
    mv s5, a0
    mv a0, s0
    call nih_riscv_fpu_task_check
    bnez a0, .Ltask_probe_exit
    li a0, -193
    j .Ltask_probe_ecall_exit
.Ltask_probe_exit:
    mv a0, s5
.Ltask_probe_ecall_exit:
    li a7, NIH_TASK_EXIT
    li a1, 0
    ecall
    j .Ltask_probe_ecall_exit
    .size nih_riscv_fpu_task_probe, .-nih_riscv_fpu_task_probe

    /*
     * Raw task-test ABI, never returns. a0 points to FloatingProbe:
     * pattern, expected fcsr, iterations, failed, actual stack address.
     * The private stack frame contains a 132-byte FP scratch context and
     * canaries. The scratch preserves caller-saved FP state around the
     * independent integer-only test-watchdog callback.
     */
    .section .iram1.nih_riscv_fpu_probe_loop, "ax", @progbits
    .balign 4
    .global nih_riscv_fpu_probe_loop
    .type nih_riscv_fpu_probe_loop, @function
nih_riscv_fpu_probe_loop:
    addi sp, sp, -160
    mv s0, a0
    lw s1, 0(s0)
    lw s2, 4(s0)
    li t0, 0x6e69686f
    sw t0, 144(sp)
    sw t0, 148(sp)
    sw sp, 16(s0)
    li s4, 0
    andi t0, s2, -32
    csrw fcsr, t0
    addi t0, s1, 0
    fmv.w.x f0, t0
    addi t0, s1, 1
    fmv.w.x f1, t0
    addi t0, s1, 2
    fmv.w.x f2, t0
    addi t0, s1, 3
    fmv.w.x f3, t0
    addi t0, s1, 4
    fmv.w.x f4, t0
    addi t0, s1, 5
    fmv.w.x f5, t0
    addi t0, s1, 6
    fmv.w.x f6, t0
    addi t0, s1, 7
    fmv.w.x f7, t0
    addi t0, s1, 8
    fmv.w.x f8, t0
    addi t0, s1, 9
    fmv.w.x f9, t0
    addi t0, s1, 10
    fmv.w.x f10, t0
    addi t0, s1, 11
    fmv.w.x f11, t0
    addi t0, s1, 12
    fmv.w.x f12, t0
    addi t0, s1, 13
    fmv.w.x f13, t0
    addi t0, s1, 14
    fmv.w.x f14, t0
    addi t0, s1, 15
    fmv.w.x f15, t0
    addi t0, s1, 16
    fmv.w.x f16, t0
    addi t0, s1, 17
    fmv.w.x f17, t0
    addi t0, s1, 18
    fmv.w.x f18, t0
    addi t0, s1, 19
    fmv.w.x f19, t0
    addi t0, s1, 20
    fmv.w.x f20, t0
    addi t0, s1, 21
    fmv.w.x f21, t0
    addi t0, s1, 22
    fmv.w.x f22, t0
    addi t0, s1, 23
    fmv.w.x f23, t0
    addi t0, s1, 24
    fmv.w.x f24, t0
    addi t0, s1, 25
    fmv.w.x f25, t0
    addi t0, s1, 26
    fmv.w.x f26, t0
    addi t0, s1, 27
    fmv.w.x f27, t0
    addi t0, s1, 28
    fmv.w.x f28, t0
    addi t0, s1, 29
    fmv.w.x f29, t0
    addi t0, s1, 30
    fmv.w.x f30, t0
    /* RNE/RTZ both round this halfway sum down; NX becomes set. */
    fadd.s f31, f0, f1, dyn
    li t0, 0x00800000
    add s3, s1, t0

.Lprobe_loop:
    fmv.x.w t0, f0
    addi t1, s1, 0
    bne t0, t1, .Lprobe_failed
    fmv.x.w t0, f1
    addi t1, s1, 1
    bne t0, t1, .Lprobe_failed
    fmv.x.w t0, f2
    addi t1, s1, 2
    bne t0, t1, .Lprobe_failed
    fmv.x.w t0, f3
    addi t1, s1, 3
    bne t0, t1, .Lprobe_failed
    fmv.x.w t0, f4
    addi t1, s1, 4
    bne t0, t1, .Lprobe_failed
    fmv.x.w t0, f5
    addi t1, s1, 5
    bne t0, t1, .Lprobe_failed
    fmv.x.w t0, f6
    addi t1, s1, 6
    bne t0, t1, .Lprobe_failed
    fmv.x.w t0, f7
    addi t1, s1, 7
    bne t0, t1, .Lprobe_failed
    fmv.x.w t0, f8
    addi t1, s1, 8
    bne t0, t1, .Lprobe_failed
    fmv.x.w t0, f9
    addi t1, s1, 9
    bne t0, t1, .Lprobe_failed
    fmv.x.w t0, f10
    addi t1, s1, 10
    bne t0, t1, .Lprobe_failed
    fmv.x.w t0, f11
    addi t1, s1, 11
    bne t0, t1, .Lprobe_failed
    fmv.x.w t0, f12
    addi t1, s1, 12
    bne t0, t1, .Lprobe_failed
    fmv.x.w t0, f13
    addi t1, s1, 13
    bne t0, t1, .Lprobe_failed
    fmv.x.w t0, f14
    addi t1, s1, 14
    bne t0, t1, .Lprobe_failed
    fmv.x.w t0, f15
    addi t1, s1, 15
    bne t0, t1, .Lprobe_failed
    fmv.x.w t0, f16
    addi t1, s1, 16
    bne t0, t1, .Lprobe_failed
    fmv.x.w t0, f17
    addi t1, s1, 17
    bne t0, t1, .Lprobe_failed
    fmv.x.w t0, f18
    addi t1, s1, 18
    bne t0, t1, .Lprobe_failed
    fmv.x.w t0, f19
    addi t1, s1, 19
    bne t0, t1, .Lprobe_failed
    fmv.x.w t0, f20
    addi t1, s1, 20
    bne t0, t1, .Lprobe_failed
    fmv.x.w t0, f21
    addi t1, s1, 21
    bne t0, t1, .Lprobe_failed
    fmv.x.w t0, f22
    addi t1, s1, 22
    bne t0, t1, .Lprobe_failed
    fmv.x.w t0, f23
    addi t1, s1, 23
    bne t0, t1, .Lprobe_failed
    fmv.x.w t0, f24
    addi t1, s1, 24
    bne t0, t1, .Lprobe_failed
    fmv.x.w t0, f25
    addi t1, s1, 25
    bne t0, t1, .Lprobe_failed
    fmv.x.w t0, f26
    addi t1, s1, 26
    bne t0, t1, .Lprobe_failed
    fmv.x.w t0, f27
    addi t1, s1, 27
    bne t0, t1, .Lprobe_failed
    fmv.x.w t0, f28
    addi t1, s1, 28
    bne t0, t1, .Lprobe_failed
    fmv.x.w t0, f29
    addi t1, s1, 29
    bne t0, t1, .Lprobe_failed
    fmv.x.w t0, f30
    addi t1, s1, 30
    bne t0, t1, .Lprobe_failed
    fmv.x.w t0, f31
    bne t0, s3, .Lprobe_failed
    csrr t0, fcsr
    bne t0, s2, .Lprobe_failed
    li t0, 0x6e69686f
    lw t1, 144(sp)
    bne t0, t1, .Lprobe_failed
    lw t1, 148(sp)
    bne t0, t1, .Lprobe_failed
    addi s4, s4, 1
    sw s4, 8(s0)
    andi t0, s4, 255
    bnez t0, .Lprobe_loop
    mv a0, sp
    call nih_riscv_fpu_save
    call nih_riscv_preemption_budget_expired
    mv s5, a0
    mv a0, sp
    call nih_riscv_fpu_restore
    bnez s5, .Lprobe_failed
    j .Lprobe_loop

.Lprobe_failed:
    li t0, 1
    sw t0, 12(s0)
    ecall
    j .Lprobe_failed
    .size nih_riscv_fpu_probe_loop, .-nih_riscv_fpu_probe_loop
