.section .text
.globl _start

.include "p2_mmio.inc"

# MMIO loads must still complete once they are non-speculative at ROB head.

_start:
    li x1, PLIC_THRESHOLD
    li x2, 3
    sw x2, 0(x1)
    lw x3, 0(x1)
    bne x3, x2, test_fail

    li x4, CLINT_MTIME_LO
    lw x5, 0(x4)
    li x6, 12
delay_loop:
    addi x6, x6, -1
    bnez x6, delay_loop
    lw x7, 0(x4)
    blt x7, x5, test_fail

    li x8, 0x04
    li x9, TUBE_ADDR
    sw x8, 0(x9)

test_pass:
    j test_pass

test_fail:
    li x8, 0xFF
    li x9, TUBE_ADDR
    sw x8, 0(x9)
fail_loop:
    j fail_loop
