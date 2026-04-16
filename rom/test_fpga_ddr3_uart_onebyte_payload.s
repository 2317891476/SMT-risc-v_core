.include "p2_mmio.inc"

.section .text
.globl _start

_start:
    li x1, UART_TXDATA_ADDR
    li x3, TUBE_ADDR
    li x4, 0x04
    sb x4, 0(x3)
    li x10, 0x58 # X
    sb x10, 0(x1)

spin:
    j spin
