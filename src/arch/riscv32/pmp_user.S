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
    bne a0, s0, .Lreturned
    addi s1, s1, -1
    bnez s1, .Lspin
    li a0, 2
    ret
.Lreturned:
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
.size nih_user_probe_body, .-nih_user_probe_body
.option pop
