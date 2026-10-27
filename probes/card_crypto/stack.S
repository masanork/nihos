/* CPU0's live task-owned PSRAM workspace. a1 is its checked private stack top.
 * The photo decoder retains its separate, unchanged 12 KiB SRAM stack. */
.section .text.nih_card_crypto_call,"ax",@progbits
.global nih_card_crypto_call
.type nih_card_crypto_call,@function
nih_card_crypto_call:
    mv t0, sp
    mv sp, a1
    addi sp, sp, -32
    sw t0, 0(sp)
    sw ra, 4(sp)
    call nih_card_crypto
    lw ra, 4(sp)
    lw t0, 0(sp)
    mv sp, t0
    ret
.size nih_card_crypto_call,.-nih_card_crypto_call
