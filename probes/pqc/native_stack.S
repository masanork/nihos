/* Measurement-only foreground switch; IRQ stack remains independently owned. */
.section .text.nih_pqc_stack_call,"ax",@progbits
.global nih_pqc_stack_call
.type nih_pqc_stack_call,@function
nih_pqc_stack_call:
    mv t0, sp
    mv sp, a0
    addi sp, sp, -32
    sw t0, 0(sp)
    sw ra, 4(sp)
    call nih_pqc_verify_fixture
    lw ra, 4(sp)
    lw t0, 0(sp)
    mv sp, t0
    ret
.size nih_pqc_stack_call,.-nih_pqc_stack_call
