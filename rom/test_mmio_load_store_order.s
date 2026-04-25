.section .text
.globl _start

.include "p2_mmio.inc"

# A younger MMIO load must wait behind older stores that are still in the SB.

_start:
    li x1, RAM_CACHEABLE_BASE
    li x2, 0x11111111
    li x3, 0x22222222
    li x4, 0x33333333

    sw x2, 64(x1)
    sw x3, 68(x1)
    sw x4, 72(x1)

    li x5, CLINT_MTIME_LO
    lw x6, 0(x5)

    lw x7, 64(x1)
    bne x7, x2, test_fail
    lw x8, 68(x1)
    bne x8, x3, test_fail
    lw x9, 72(x1)
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
