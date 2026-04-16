.include "p2_mmio.inc"

.equ LOADER_SEND_STRING_ADDR, 0x00000818
.equ LOADER_MSG_LOAD_OK_ADDR, 0x000008FD

.section .text
.globl _start

_start:
    li x1, TUBE_ADDR
    li x2, 0x04
    sb x2, 0(x1)
    li x10, LOADER_MSG_LOAD_OK_ADDR
    li x5, LOADER_SEND_STRING_ADDR
    jalr ra, 0(x5)
spin:
    j spin
