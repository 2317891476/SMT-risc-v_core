.section .text
.globl _start

.include "p2_mmio.inc"

# Fall-through ALU work after a not-taken branch must still commit normally.

_start:
    li x1, 1
    li x2, 2
    li x3, 0

    beq x1, x2, after_work
    addi x3, x0, 42

after_work:
    li x5, 42
    bne x3, x5, test_fail

    li x6, 0x04
    li x7, TUBE_ADDR
    sw x6, 0(x7)

test_pass:
    j test_pass

test_fail:
    li x6, 0xFF
    li x7, TUBE_ADDR
    sw x6, 0(x7)
fail_loop:
    j fail_loop
