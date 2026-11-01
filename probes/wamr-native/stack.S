/* CPU0-only WAMR call. a6 is the top of a checked 64 KiB PSRAM stack and is
 * not forwarded to nih_wamr_run(a0..a5). */
.section .text.nih_wamr_call,"ax",@progbits
.global nih_wamr_call
.type nih_wamr_call,@function
nih_wamr_call:
    mv t0, sp
    mv sp, a6
    addi sp, sp, -32
    sw t0, 0(sp)
    sw ra, 4(sp)
    call nih_wamr_run
    lw ra, 4(sp)
    lw t0, 0(sp)
    mv sp, t0
    ret
.size nih_wamr_call,.-nih_wamr_call
