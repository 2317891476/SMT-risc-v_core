.section .text
.globl _start

.include "p2_mmio.inc"

# Test: L2 adjacent line boundary read/write
# Verifies:
# - data on the last word of one line and first words of the next line stay independent
# - repeated reads after refill hit the correct line
# - overwrites near a line boundary do not alias across lines

_start:
    li x1, 0x00001A1C

    li x2, 0x11111111
    sw x2, 0(x1)        # Last word of line N
    li x3, 0x22222222
    sw x3, 4(x1)        # First word of line N+1
    li x4, 0x33333333
    sw x4, 8(x1)        # Second word of line N+1

    li x5, 64
drain_first_boundary:
    addi x5, x5, -1
    bnez x5, drain_first_boundary

    lw x6, 0(x1)
    bne x6, x2, test_fail
    lw x7, 4(x1)
    bne x7, x3, test_fail
    lw x8, 8(x1)
    bne x8, x4, test_fail

    li x2, 0xA5A5A5A5
    sw x2, 0(x1)
    li x3, 0x5A5A5A5A
    sw x3, 4(x1)

    li x5, 64
drain_second_boundary:
    addi x5, x5, -1
    bnez x5, drain_second_boundary

    lw x6, 0(x1)
    bne x6, x2, test_fail
    lw x7, 4(x1)
    bne x7, x3, test_fail
    lw x8, 8(x1)
    li x9, 0x33333333
    bne x8, x9, test_fail

    # Re-read in reverse order to make sure both lines remain stable on hits.
    lw x10, 8(x1)
    bne x10, x9, test_fail
    lw x11, 4(x1)
    bne x11, x3, test_fail
    lw x12, 0(x1)
    bne x12, x2, test_fail

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
