/* CPU0 foreground only, after all worker tasks are quiescent. Borrow only its
 * existing 12 KiB worker-stack span, never CPU1's or either IRQ stack. */
.section .text.nih_photo_call,"ax",@progbits
.global nih_photo_call
.type nih_photo_call,@function
nih_photo_call:
    mv t0, sp
    li sp, 0x4ff6b000
    addi sp, sp, -32
    sw t0, 0(sp)
    sw ra, 4(sp)
    call nih_photo_decode
    lw ra, 4(sp)
    lw t0, 0(sp)
    mv sp, t0
    ret
.size nih_photo_call,.-nih_photo_call
