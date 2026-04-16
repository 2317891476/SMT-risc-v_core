.include "p2_mmio.inc"

.section .text
.globl _start

_start:
    li x1, TUBE_ADDR
    li x2, 0x04
    sb x2, 0(x1)
payload_spin:
    j payload_spin
