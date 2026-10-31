/* Foreground only. a0=request, a1=owner-checked, 16-byte-aligned PSRAM stack top. */
.section .flash.xytext,"ax",@progbits
.global nih_xy_render_call
.type nih_xy_render_call,@function
nih_xy_render_call:
    mv t0, sp
    mv sp, a1
    addi sp, sp, -16
    sw t0, 0(sp)
    sw ra, 4(sp)
    call nih_xy_render
    lw ra, 4(sp)
    lw t0, 0(sp)
    mv sp, t0
    ret
.size nih_xy_render_call,.-nih_xy_render_call
