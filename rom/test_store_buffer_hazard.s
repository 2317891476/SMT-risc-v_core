.section .text
.globl _start

.include "p2_mmio.inc"

# Test: Store Buffer hazard handling
# Verifies:
# - partial-overlap store/load ordering
# - byte/halfword stores become visible correctly to a word load

_start:
    li x1, 0x00001300

    sw x0, 0(x1)

    li x2, 0x000000AA
    sb x2, 0(x1)
    lw x3, 0(x1)
    li x4, 0x000000AA
    bne x3, x4, test_fail

    li x5, 0x0000BBCC
    sh x5, 2(x1)
    lw x6, 0(x1)
    li x7, 0xBBCC00AA
    bne x6, x7, test_fail

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
