.section .text
.globl _start

.include "p2_mmio.inc"

# A taken branch should flush younger fall-through ALU work before commit.

_start:
    li x5, 0

    beq x0, x0, target
    addi x5, x0, 99
    addi x6, x0, 77

target:
    bne x5, x0, test_fail
    bne x6, x0, test_fail

    li x1, 0x04
    li x2, TUBE_ADDR
    sw x1, 0(x2)

test_pass:
    j test_pass

test_fail:
    li x1, 0xFF
    li x2, TUBE_ADDR
    sw x1, 0(x2)
fail_loop:
    j fail_loop
