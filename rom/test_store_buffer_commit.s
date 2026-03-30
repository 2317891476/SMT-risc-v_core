.section .text
.globl _start

.include "p2_mmio.inc"

# Test: Store Buffer commit boundary
# Verifies:
# - back-to-back stores retire correctly
# - committed stores become visible in memory in program order

_start:
    li x1, 0x00001100

    sw x0, 0(x1)
    sw x0, 4(x1)
    sw x0, 8(x1)

    li x2, 0x00000011
    li x3, 0x00000022
    li x4, 0x00000033

    sw x2, 0(x1)
    sw x3, 4(x1)
    add x5, x2, x3
    li x6, 0x00000033
    bne x5, x6, test_fail
    sw x4, 8(x1)

    lw x7, 0(x1)
    bne x7, x2, test_fail
    lw x8, 4(x1)
    bne x8, x3, test_fail
    lw x9, 8(x1)
    bne x9, x4, test_fail

    li x10, 0x04
    li x11, TUBE_ADDR
    sw x10, 0(x11)

test_pass:
    j test_pass

test_fail:
    li x10, 0xFF
    li x11, TUBE_ADDR
    sw x10, 0(x11)
fail_loop:
    j fail_loop
