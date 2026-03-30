.section .text
.globl _start

.include "p2_mmio.inc"

# Test: Flush discards wrong-path stores
# Verifies:
# - taken branch flushes younger speculative stores
# - flushed stores never become architecturally visible

_start:
    li x1, 0x00001400
    li x2, 0xDEADBEEF

    sw x0, 0(x1)
    sw x0, 4(x1)

    beq x0, x0, branch_taken
    sw x2, 0(x1)
    sw x2, 4(x1)

branch_taken:
    lw x3, 0(x1)
    bne x3, x0, test_fail
    lw x4, 4(x1)
    bne x4, x0, test_fail

    li x5, 0x04
    li x6, TUBE_ADDR
    sw x5, 0(x6)

test_pass:
    j test_pass

test_fail:
    li x5, 0xFF
    li x6, TUBE_ADDR
    sw x5, 0(x6)
fail_loop:
    j fail_loop
