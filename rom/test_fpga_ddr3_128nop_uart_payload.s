.include "p2_mmio.inc"

.section .text
.globl _start

_start:
    .rept 28
    nop
    .endr
    li x1, UART_TXDATA_ADDR
    li x2, 'Y'
    sb x2, 0(x1)
spin:
    j spin
