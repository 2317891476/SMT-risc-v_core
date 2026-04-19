.include "p2_mmio.inc"

.section .text
.globl _start

_start:
    csrr x7, mhartid
    bnez x7, thread1_spin

    li x5, TUBE_ADDR
    li x6, 0x31
    sb x6, 0(x5)

    li x5, 0x80000000
    jalr x0, 0(x5)

.org 0x800
thread1_spin:
    j thread1_spin
