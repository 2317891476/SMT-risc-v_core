.section .text
.globl _start

.include "p2_mmio.inc"

# Long sequential store/readback stream used to catch store-buffer pointer,
# commit, and drain bugs that only show up after many store instructions.
_start:
    li x1, 0x00002000
    mv x2, x1
    li x3, 0
    li x4, 256

store_loop:
    sw x3, 0(x2)
    addi x2, x2, 4
    addi x3, x3, 1
    addi x4, x4, -1
    bnez x4, store_loop

    li x5, 1024
drain_wait:
    addi x5, x5, -1
    bnez x5, drain_wait

    mv x2, x1
    li x3, 0
    li x4, 256

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
