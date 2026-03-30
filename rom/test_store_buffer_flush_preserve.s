.section .text
.globl _start

.include "p2_mmio.inc"

# Test: Flush preserves older stores while discarding younger wrong-path stores
# Verifies:
# - an older store before a taken branch remains visible
# - a younger same-address wrong-path store is discarded
# - unrelated wrong-path stores are also discarded

_start:
    li x1, 0x00001700

    sw x0, 0(x1)
    sw x0, 4(x1)

    li x2, 0x13579BDF
    sw x2, 0(x1)          # Older store that must survive the flush.

    beq x0, x0, branch_taken
    li x3, 0x2468ACE0
    sw x3, 0(x1)          # Younger same-address store must be flushed.
    sw x3, 4(x1)          # Younger independent store must also be flushed.

branch_taken:
    lw x4, 0(x1)
    bne x4, x2, test_fail
    lw x5, 4(x1)
    bne x5, x0, test_fail

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
