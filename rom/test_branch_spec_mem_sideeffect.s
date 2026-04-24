.section .text
.globl _start

.include "p2_mmio.inc"

# Wrong-path stores, including MMIO, must not issue before the older branch
# resolves. If the MMIO store reaches TUBE, the test fails immediately.

_start:
    li x1, RAM_CACHEABLE_BASE
    sw x0, 0(x1)

    li x2, 0x12345678
    li x3, 0xFF
    li x4, TUBE_ADDR

    beq x0, x0, target
    sw x2, 0(x1)
    sw x3, 0(x4)

target:
    lw x5, 0(x1)
    bne x5, x0, test_fail

    li x6, 0x04
    sw x6, 0(x4)

test_pass:
    j test_pass

test_fail:
    li x6, 0xFF
    sw x6, 0(x4)
fail_loop:
    j fail_loop
