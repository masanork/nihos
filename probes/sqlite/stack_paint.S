/* Leaf helper writes only below the caller's live SP. IRQ uses its own stack. */
.section .text.nih_sqlite_stack_paint,"ax",@progbits
.global nih_sqlite_stack_paint
.type nih_sqlite_stack_paint,@function
nih_sqlite_stack_paint:
    mv a1, sp
    li t0, 0x5a7ec319
1:  bgeu a0, a1, 2f
    sw t0, 0(a0)
    addi a0, a0, 4
    j 1b
2:  mv a0, a1
    ret
.size nih_sqlite_stack_paint, .-nih_sqlite_stack_paint
