.section .text
.globl _start

.include "p2_mmio.inc"

# Test: Store-to-load forwarding
# Verifies:
# - immediate load after same-address store observes the new value

_start:
    li x1, 0x00001200

    sw x0, 0(x1)
    sw x0, 4(x1)

    li x2, 0xCAFEBABE
    sw x2, 0(x1)
    lw x3, 0(x1)
    bne x3, x2, test_fail

    li x4, 0x0F0E0D0C
    sw x4, 4(x1)
    lw x5, 4(x1)
    bne x5, x4, test_fail

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
