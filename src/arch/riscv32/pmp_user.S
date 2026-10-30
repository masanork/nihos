/* U-mode text for the hardware PMP probe. Product images do not link this file.
 * The grant is exactly this section: RX, not writable. It has its own
 * trampoline because the kernel trampoline stays outside the grant.
 * No GP-relative loads and no stack use. A rejected SP is the explicit
 * li sp, 0 immediately before ecall. */
#include "task_call_numbers.inc"

.section .flash.text.user, "ax", @progbits
.option push
.option norvc
.option norelax
.balign 4

.global nih_user_probe_trampoline
.type nih_user_probe_trampoline, @function
nih_user_probe_trampoline:
    mv t0, a0
    mv a0, a1
    jalr t0
    li a7, NIH_TASK_EXIT
    li a1, 0
    ecall
    j nih_user_probe_trampoline
.size nih_user_probe_trampoline, .-nih_user_probe_trampoline

.balign 4
.global nih_user_probe_body
.type nih_user_probe_body, @function
/* a0 = case, a2 = private arena base. */
nih_user_probe_body:
    beqz a0, .Lreturn
    li t0, 1
    beq a0, t0, .Lload
    li t0, 2
    beq a0, t0, .Lstore_code
    li t0, 3
    beq a0, t0, .Lexecute_data
    li t0, 4
    beq a0, t0, .Lbad_sp
    li t0, 5
    beq a0, t0, .Lprivileged
    li t0, 6
    beq a0, t0, .Lmmio_hp
    li t0, 7
    beq a0, t0, .Lmmio_cpu
    li t0, 8
    beq a0, t0, .Lmmio_subsys
    li t0, 9
    beq a0, t0, .Lkernel_read
    li t0, 10
    beq a0, t0, .Lrom_read
    li t0, 11
    beq a0, t0, .Lrom_execute
    li a0, 9
    ret

.Lreturn:
    li a7, NIH_TASK_CURRENT
    li a0, 0
    li a1, 0
    ecall
    bnez a1, .Lcurrent_failed
    beqz a0, .Lcurrent_failed
    li a7, NIH_TASK_TICKS
    li a0, 0
    li a1, 0
    ecall
    mv s0, a0
    li s1, 200000
.Lspin:
    li a7, NIH_TASK_TICKS
    li a0, 0
    li a1, 0
    ecall
    bne a0, s0, .Lticks_moved
    addi s1, s1, -1
    bnez s1, .Lspin
    li a0, 2
    ret
.Lticks_moved:
    /* now() can move when the ecall samples the counter, before the timer
     * interrupt is counted. A short extra sample leaves room for that IRQ
     * without holding the emulator for the whole 200000-call cap. */
    li s1, 1000
.Lsettle:
    li a7, NIH_TASK_TICKS
    li a0, 0
    li a1, 0
    ecall
    addi s1, s1, -1
    bnez s1, .Lsettle
    li a0, 1
    ret
.Lcurrent_failed:
    li a0, 3
    ret

.Lload:
    li t0, 0
    lw t0, 0(t0)
    li a0, 4
    ret

.Lstore_code:
    auipc t0, 0
    sw t0, 0(t0)
    li a0, 5
    ret

.Lexecute_data:
    /* addi a0, zero, 6; ret. Execution would exit 6. A fetch fault exits -70. */
    li t0, 0x00600513
    sw t0, 0(a2)
    li t0, 0x00008067
    sw t0, 4(a2)
    jalr zero, 0(a2)
    li a0, 6
    ret

.Lbad_sp:
    li a7, NIH_TASK_CURRENT
    li a0, 0
    li a1, 0
    li sp, 0
    ecall
    li a0, 7
    ret

.Lprivileged:
    csrr t0, mstatus
    li a0, 8
    ret

/* A completed load returns 10, 11, or 12. A load fault exits -70.
 * 0x3FF10000 is the cache register block and 0x20800000 is CLIC.
 * Both sit in the old locked windows and are registers this kernel reads.
 * With entries 0 and 1 OFF, the CLIC load stalled the hart. Timeout alone
 * does not locate the stall. 0x20000000 did not answer either. Do not load
 * that base. */
.Lmmio_hp:
    lui t0, 0x50000
    lw t0, 0(t0)
    li a0, 10
    ret

.Lmmio_cpu:
    lui t0, 0x3ff10
    lw t0, 0(t0)
    li a0, 11
    ret

.Lmmio_subsys:
    lui t0, 0x20800
    lw t0, 0(t0)
    li a0, 12
    ret

/* These are valid memory addresses. Denying address zero alone cannot
 * distinguish PMP confinement from the platform's invalid-address PMA. */
.Lkernel_read:
    lui t0, 0x4ff00
    lw t0, 0(t0)
    li a0, 13
    ret

.Lrom_read:
    lui t0, 0x4fc00
    lw t0, 0(t0)
    li a0, 14
    ret

.Lrom_execute:
    lui t0, 0x4fc00
    jalr zero, 0(t0)
.size nih_user_probe_body, .-nih_user_probe_body
.option pop
