/*
 * Native RV32 trap entry and bounded context-switch test helpers.
 *
 * The ESP-IDF bring-up image installs this entry around bounded exception
 * and timer tests. Interrupts remain disabled while the dispatcher runs;
 * permanent vector ownership, native SMP FPU ownership, and nesting come later.
 */

#include "context_offsets.inc"
#include "task_call_numbers.inc"
#if __has_include("sdkconfig.h")
#include "sdkconfig.h"
#endif

    /* Keep the temporary vector in IRAM and out of flash/MMU aliasing. */
    .section .iram1.nih_riscv_trap_entry, "ax", @progbits
    /* ESP32-P4 CLIC ignores the low six mtvec address bits. */
    .balign 64
    .global nih_riscv_trap_entry
    .type nih_riscv_trap_entry, @function

/*
 * extern fn nih_riscv_trap_dispatch(
 *     interrupted: *IntegerContext,
 *     raw_mcause: u32,
 *     hart_id: u32,
 *     raw_mstatus: u32,
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

    /* Callee-saved registers carry trap state across guard and dispatch calls. */
    csrr s10, mcause
    csrr s11, mstatus
    mv s9, sp
    csrr s8, mhartid

    /* Dispatch on a bounded, private stack for this hart. */
    li t0, 2
    bgeu s8, t0, .Linvalid_context
    /* Preserve an opted-in task's FP bank before any C or Zig call. The
     * bootstrap opts in even with FS=Off to protect IDF's lazy physical owner.
     */
    la t0, nih_riscv_current_floating_states
    slli t1, s8, 2
    add t0, t0, t1
    lw a0, 0(t0)
    beqz a0, .Lno_floating_save
    li t0, 0x6000
    csrs mstatus, t0
    call nih_riscv_fpu_save
    la t0, nih_riscv_floating_saves
    slli t1, s8, 2
    add t0, t0, t1
    lw t1, 0(t0)
    addi t1, t1, 1
    sw t1, 0(t0)
.Lno_floating_save:
    /* The kernel dispatcher and all guard helpers stay integer-only. */
    li t0, 0x6000
    csrc mstatus, t0
    la t0, nih_riscv_interrupt_stack_tops
    slli t1, s8, 2
    add t0, t0, t1
    lw t0, 0(t0)
    beqz t0, .Linvalid_context
    andi t1, t0, 15
    bnez t1, .Linvalid_context
    mv s7, t0
#if CONFIG_ESP_SYSTEM_HW_STACK_GUARD
    call esp_hw_stack_guard_monitor_stop
    la a0, nih_riscv_interrupt_stack_bottoms
    slli t1, s8, 2
    add a0, a0, t1
    lw a0, 0(a0)
    mv a1, s7
    call esp_hw_stack_guard_set_bounds
#endif
    mv sp, s7
#if CONFIG_ESP_SYSTEM_HW_STACK_GUARD
    call esp_hw_stack_guard_monitor_start
#endif
    mv a0, s9
    mv a1, s10
    mv a2, s8
    mv a3, s11
    call nih_riscv_trap_dispatch
    beqz a0, .Linvalid_context

    mv s9, a0
#if CONFIG_ESP_SYSTEM_HW_STACK_GUARD
    call esp_hw_stack_guard_monitor_stop
    slli t1, s8, 2
    la a0, nih_riscv_selected_stack_mins
    add a0, a0, t1
    lw a0, 0(a0)
    la a1, nih_riscv_selected_stack_maxs
    add a1, a1, t1
    lw a1, 0(a1)
    call esp_hw_stack_guard_set_bounds
#endif
    mv sp, s9
#if CONFIG_ESP_SYSTEM_HW_STACK_GUARD
    call esp_hw_stack_guard_monitor_start
#endif
    /* All C/Zig calls are complete. Restore the chosen bank, then its FS
     * status below. Integer-only tasks keep a null bank and FS=Off.
     */
    la t0, nih_riscv_selected_floating_states
    slli t1, s8, 2
    add t0, t0, t1
    lw a0, 0(t0)
    la t0, nih_riscv_current_floating_states
    add t0, t0, t1
    sw a0, 0(t0)
    beqz a0, .Lno_floating_restore
    li t0, 0x6000
    csrs mstatus, t0
    call nih_riscv_fpu_restore
    la t0, nih_riscv_floating_restores
    slli t1, s8, 2
    add t0, t0, t1
    lw t1, 0(t0)
    addi t1, t1, 1
    sw t1, 0(t0)
.Lno_floating_restore:
    /* Dispatcher combines the selected task's mstatus with the current
     * trap's complete mcause so mret unwinds this CLIC entry. */
    la t0, nih_riscv_selected_return_states
    slli t1, s8, 3
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

.Linvalid_context:
    wfi
    j .Linvalid_context

    .size nih_riscv_trap_entry, .-nih_riscv_trap_entry

    .balign 4
    .global nih_riscv_exception_roundtrip
    .type nih_riscv_exception_roundtrip, @function
nih_riscv_exception_roundtrip:
    /*
     * Preserve ESP-IDF's vector state. MIE is cleared before mtvec changes,
     * so no maskable interrupt can enter through the temporary vector.
     */
    addi sp, sp, -16
    sw ra, 12(sp)
    sw s0, 8(sp)
    sw s1, 4(sp)
    csrr s0, mstatus
    sw s0, 0(sp)
    csrci mstatus, 8
    csrr s1, mtvec
    la t2, nih_riscv_trap_entry
    ori t2, t2, 3
    csrw mtvec, t2
    ecall
    csrw mtvec, s1
    lw t0, 0(sp)
    lw s1, 4(sp)
    lw s0, 8(sp)
    lw ra, 12(sp)
    addi sp, sp, 16
    csrw mstatus, t0
    li a0, 1
    ret

    .size nih_riscv_exception_roundtrip, .-nih_riscv_exception_roundtrip

    .balign 4
    .global nih_riscv_timer_window
    .type nih_riscv_timer_window, @function
nih_riscv_timer_window:
    /* The C lease masks all other external CPU0 lines and saves threshold. */
    addi sp, sp, -32
    sw ra, 28(sp)
    sw s1, 24(sp)
    csrr t0, mstatus
    sw t0, 0(sp)
    csrci mstatus, 8
    call nih_espidf_native_timer_enter
    csrr s1, mtvec
    la t0, nih_riscv_trap_entry
    ori t0, t0, 3
    csrw mtvec, t0
    call nih_riscv_native_timer_prepare
    sw a0, 4(sp)
    beqz a0, .Ltimer_window_restore
    csrsi mstatus, 8
    call nih_riscv_native_timer_run
    sw a0, 4(sp)
    csrci mstatus, 8
.Ltimer_window_restore:
    call nih_riscv_native_timer_finish
    lw t0, 4(sp)
    and t0, t0, a0
    sw t0, 4(sp)
    /* Complete timer stop/W1C writes before restoring the IDF vector. */
    fence iorw, iorw
    csrw mtvec, s1
    call nih_espidf_native_timer_leave
    lw t0, 4(sp)
    and a0, a0, t0
    lw t0, 0(sp)
    lw s1, 24(sp)
    lw ra, 28(sp)
    addi sp, sp, 32
    csrw mstatus, t0
    ret
    .size nih_riscv_timer_window, .-nih_riscv_timer_window

    .balign 4
    .global nih_riscv_service_window
    .type nih_riscv_service_window, @function
nih_riscv_service_window:
    /* CPU1's IDF stack is the foreground/idle stack; the shared trap entry
     * switches to that hart's private interrupt stack for service work. */
    addi sp, sp, -32
    sw ra, 28(sp)
    sw s1, 24(sp)
    csrr t0, mstatus
    sw t0, 0(sp)
    csrci mstatus, 8
    call nih_espidf_native_service_enter
    csrr s1, mtvec
    la t0, nih_riscv_trap_entry
    ori t0, t0, 3
    csrw mtvec, t0
    call nih_riscv_native_service_prepare
    sw a0, 4(sp)
    beqz a0, .Lservice_window_restore
    csrsi mstatus, 8
    call nih_riscv_native_service_run
    sw a0, 4(sp)
    csrci mstatus, 8
.Lservice_window_restore:
    call nih_riscv_native_service_finish
    fence iorw, iorw
    csrw mtvec, s1
    call nih_espidf_native_service_leave
    lw t0, 4(sp)
    and a0, a0, t0
    lw t0, 0(sp)
    lw s1, 24(sp)
    lw ra, 28(sp)
    addi sp, sp, 32
    csrw mstatus, t0
    ret
    .size nih_riscv_service_window, .-nih_riscv_service_window

    .balign 4
    .global nih_riscv_task_trampoline
    .type nih_riscv_task_trampoline, @function
nih_riscv_task_trampoline:
    /* Initial context supplies task entry in a0 and argument in a1. */
    mv t0, a0
    mv a0, a1
    jalr t0
    /* A task entry returns its signed exit code in a0. */
    li a7, NIH_TASK_EXIT
    li a1, 0
    ecall
    j .Linvalid_context

    .size nih_riscv_task_trampoline, .-nih_riscv_task_trampoline

    .balign 4
    .global nih_riscv_context_test_yield
    .type nih_riscv_context_test_yield, @function
nih_riscv_context_test_yield:
    ecall
    j .Linvalid_context

    .size nih_riscv_context_test_yield, .-nih_riscv_context_test_yield

    .balign 4
    .global nih_riscv_task_call
    .type nih_riscv_task_call, @function
nih_riscv_task_call:
    /* C ABI: number/argument/payload in a0/a1/a2; u64 result in a0/a1. */
    mv a7, a0
    mv a0, a1
    mv a1, a2
    ecall
    ret
    .size nih_riscv_task_call, .-nih_riscv_task_call

    .balign 4
    .global nih_riscv_task_exit
    .type nih_riscv_task_exit, @function
nih_riscv_task_exit:
    li a7, NIH_TASK_EXIT
    li a1, 0
    ecall
    j .Linvalid_context
    .size nih_riscv_task_exit, .-nih_riscv_task_exit

    .balign 4
    .global nih_riscv_read_gp
    .type nih_riscv_read_gp, @function
nih_riscv_read_gp:
    mv a0, gp
    ret
    .size nih_riscv_read_gp, .-nih_riscv_read_gp

    .balign 4
    .global nih_riscv_read_tp
    .type nih_riscv_read_tp, @function
nih_riscv_read_tp:
    mv a0, tp
    ret
    .size nih_riscv_read_tp, .-nih_riscv_read_tp
