.include "p2_mmio.inc"

.section .text
.globl _start

_start:
    li x5, 0

    .rept 256
    addi x5, x5, 1
    .endr

    li x1, UART_TXDATA_ADDR
    li x10, 0x59 # Y
    sb x10, 0(x1)

spin:
    j spin
