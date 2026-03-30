.section .text
.globl _start

.include "p2_mmio.inc"

# Test: L2 cached subword store hit path
# Verifies:
# - cacheable word stores become visible after draining through the SB/L2 path
# - byte and halfword stores update only the addressed byte lanes
# - neighboring cached words in the same line are not corrupted

_start:
    li x1, 0x00001800

    li x2, 0x11223344
    sw x2, 0(x1)
    li x3, 0x55667788
    sw x3, 4(x1)

    li x4, 64
drain_first_wave:
    addi x4, x4, -1
    bnez x4, drain_first_wave

    lw x5, 0(x1)
    bne x5, x2, test_fail
    lw x6, 4(x1)
    bne x6, x3, test_fail

    li x7, 0xAA
    sb x7, 1(x1)
    li x8, 0xCCDD
    sh x8, 2(x1)
    li x9, 0x99
    sb x9, 7(x1)

    li x10, 64
drain_second_wave:
    addi x10, x10, -1
    bnez x10, drain_second_wave

    lw x11, 0(x1)
    li x12, 0xCCDDAA44
    bne x11, x12, test_fail

    lw x13, 4(x1)
    li x14, 0x99667788
    bne x13, x14, test_fail

    li x15, 0x04
    li x16, TUBE_ADDR
    sw x15, 0(x16)

test_pass:
    j test_pass

test_fail:
    li x15, 0xFF
    li x16, TUBE_ADDR
    sw x15, 0(x16)
fail_loop:
    j fail_loop
