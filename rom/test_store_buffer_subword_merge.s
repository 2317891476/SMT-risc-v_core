.section .text
.globl _start

.include "p2_mmio.inc"

# Test: Store Buffer subword merge and sign/zero extension
# Verifies:
# - byte and halfword stores align into the correct lanes
# - immediate subword reads observe the latest data
# - full-word readback sees the merged result

_start:
    li x1, 0x00001600

    sw x0, 0(x1)

    li x2, 0x11223344
    sw x2, 0(x1)

    li x3, 0x000000AA
    sb x3, 1(x1)
    lbu x4, 1(x1)
    li x5, 0x000000AA
    bne x4, x5, test_fail
    lb x4, 1(x1)
    li x5, -86
    bne x4, x5, test_fail

    li x6, 0x0000BBCC
    sh x6, 2(x1)
    lhu x7, 2(x1)
    li x8, 0x0000BBCC
    bne x7, x8, test_fail
    lb x7, 3(x1)
    li x8, -69
    bne x7, x8, test_fail

    lbu x9, 0(x1)
    li x10, 0x44
    bne x9, x10, test_fail

    lw x11, 0(x1)
    li x12, 0xBBCCAA44
    bne x11, x12, test_fail

    li x13, 0x04
    li x14, TUBE_ADDR
    sw x13, 0(x14)

test_pass:
    j test_pass

test_fail:
    li x13, 0xFF
    li x14, TUBE_ADDR
    sw x13, 0(x14)
fail_loop:
    j fail_loop
