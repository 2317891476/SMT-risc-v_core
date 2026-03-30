.section .text
.globl _start

.include "p2_mmio.inc"

# Test: L2 cacheable data survives repeated MMIO ping-pong traffic
# Verifies:
# - cacheable lines remain stable across repeated CLINT/PLIC accesses
# - MMIO readback reflects the latest written values
# - CLINT mtime keeps moving while cacheable data is revisited

_start:
    li x1, 0x00001D40
    li x2, PLIC_THRESHOLD
    li x3, CLINT_MTIME_LO

    li x4, 0
    li x5, 6

mmio_ping_loop:
    sw x4, 0(x1)
    addi x6, x4, 32
    sw x6, 32(x1)

    sw x4, 0(x2)
    lw x7, 0(x2)
    bne x7, x4, test_fail

    lw x8, 0(x3)
    li x9, 16
mmio_ping_delay:
    addi x9, x9, -1
    bnez x9, mmio_ping_delay
    lw x10, 0(x3)
    blt x10, x8, test_fail

    lw x11, 0(x1)
    bne x11, x4, test_fail
    lw x12, 32(x1)
    bne x12, x6, test_fail

    addi x4, x4, 1
    addi x5, x5, -1
    bnez x5, mmio_ping_loop

    li x13, 5
    lw x11, 0(x1)
    bne x11, x13, test_fail
    li x14, 37
    lw x12, 32(x1)
    bne x12, x14, test_fail
    lw x15, 0(x2)
    bne x15, x13, test_fail

    li x16, 0x04
    li x17, TUBE_ADDR
    sw x16, 0(x17)

test_pass:
    j test_pass

test_fail:
    li x16, 0xFF
    li x17, TUBE_ADDR
    sw x16, 0(x17)
fail_loop:
    j fail_loop
