.section .text
.globl _start

.include "p2_mmio.inc"

# Test: Store Buffer latest write wins on the same address
# Verifies:
# - repeated stores to one word forward the newest value
# - partial stores update the correct byte lanes
# - a later full-word store overwrites any older partial data

_start:
    li x1, 0x00001C00

    sw x0, 0(x1)

    li x2, 0x11112222
    sw x2, 0(x1)
    lw x3, 0(x1)
    bne x3, x2, test_fail

    li x2, 0x33334444
    sw x2, 0(x1)
    lw x3, 0(x1)
    bne x3, x2, test_fail

    li x4, 0xAA
    sb x4, 1(x1)
    lbu x5, 1(x1)
    bne x5, x4, test_fail
    lw x6, 0(x1)
    li x7, 0x3333AA44
    bne x6, x7, test_fail

    li x4, 0xCCDD
    sh x4, 2(x1)
    lhu x5, 2(x1)
    li x7, 0x0000CCDD
    bne x5, x7, test_fail
    lw x6, 0(x1)
    li x7, 0xCCDDAA44
    bne x6, x7, test_fail

    li x2, 0x55667788
    sw x2, 0(x1)
    lw x3, 0(x1)
    bne x3, x2, test_fail
    lbu x4, 1(x1)
    li x5, 0x77
    bne x4, x5, test_fail

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
