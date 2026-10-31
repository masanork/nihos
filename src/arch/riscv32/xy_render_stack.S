/* MIE clear on entry/return. a0=request, a1=checked stack top, a2=old MIE. */
.section .flash.xytext,"ax",@progbits
.global nih_xy_render_call
.type nih_xy_render_call,@function
nih_xy_render_call:
    mv t0, sp
    mv sp, a1
    addi sp, sp, -16
    sw t0, 0(sp)
    sw ra, 4(sp)
    csrs mstatus, a2
    call nih_xy_render
    csrci mstatus, 8
    lw ra, 4(sp)
    lw t0, 0(sp)
    mv sp, t0
    ret
.size nih_xy_render_call,.-nih_xy_render_call
/* Same foreground contract, a0..a3 are the evaluator's copied scalar args. */
.section .flash.xytext.eval_bridge,"ax",@progbits
.global nih_xy_eval_call
.type nih_xy_eval_call,@function
nih_xy_eval_call:
    mv t0, sp
    mv sp, a4
    addi sp, sp, -16
    sw t0, 0(sp)
    sw ra, 4(sp)
    csrs mstatus, a5
    call nih_xy_eval_on_stack
    csrci mstatus, 8
    lw ra, 4(sp)
    lw t0, 0(sp)
    mv sp, t0
    ret
.size nih_xy_eval_call,.-nih_xy_eval_call
