.section .text
.globl _start

.include "p2_mmio.inc"

# Test: Store Buffer streaming stores across multiple cache lines
# Verifies:
# - a longer burst of stores commits correctly across adjacent lines
# - readback stays ordered after the buffer drains
# - a second overwrite pass updates the whole span cleanly

_start:
    li x1, 0x00001C80

    mv x2, x1
    li x3, 0
    li x4, 16
seed_stream_first:
    sw x3, 0(x2)
    addi x2, x2, 4
    addi x3, x3, 1
    addi x4, x4, -1
    bnez x4, seed_stream_first

    li x5, 96
drain_stream_first:
    addi x5, x5, -1
    bnez x5, drain_stream_first

    mv x2, x1
    li x3, 0
    li x4, 16
check_stream_first:
    lw x6, 0(x2)
    bne x6, x3, test_fail
    addi x2, x2, 4
    addi x3, x3, 1
    addi x4, x4, -1
    bnez x4, check_stream_first

    mv x2, x1
    li x3, 16
    li x4, 16
seed_stream_second:
    sw x3, 0(x2)
    addi x2, x2, 4
    addi x3, x3, 1
    addi x4, x4, -1
    bnez x4, seed_stream_second

    li x5, 96
drain_stream_second:
    addi x5, x5, -1
    bnez x5, drain_stream_second

    mv x2, x1
    li x3, 16
    li x4, 16
check_stream_second:
    lw x6, 0(x2)
    bne x6, x3, test_fail
    addi x2, x2, 4
    addi x3, x3, 1
    addi x4, x4, -1
    bnez x4, check_stream_second

    li x7, 0x04
    li x8, TUBE_ADDR
    sw x7, 0(x8)

test_pass:
    j test_pass

test_fail:
    li x7, 0xFF
    li x8, TUBE_ADDR
    sw x7, 0(x8)
fail_loop:
    j fail_loop
