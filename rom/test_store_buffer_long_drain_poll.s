.section .text
.globl _start

.include "p2_mmio.inc"

# Mirrors the DDR3 loader's store pattern more closely: each RAM store is
# followed by an uncached MMIO load, forcing LSU/store-buffer drain interaction.
_start:
    li x1, 0x00002000
    li x9, DDR3_STATUS_ADDR
    mv x2, x1
    li x3, 0
    li x4, 192

store_poll_loop:
    sw x3, 0(x2)
    lw x10, 0(x9)
    addi x2, x2, 4
    addi x3, x3, 1
    addi x4, x4, -1
    bnez x4, store_poll_loop

    li x5, 1024
drain_wait:
    addi x5, x5, -1
    bnez x5, drain_wait

    mv x2, x1
    li x3, 0
    li x4, 192

check_loop:
    lw x6, 0(x2)
    bne x6, x3, test_fail
    addi x2, x2, 4
    addi x3, x3, 1
    addi x4, x4, -1
    bnez x4, check_loop

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
