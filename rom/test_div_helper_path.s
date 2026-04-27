.section .text
.globl _start

.include "p2_mmio.inc"

.extern __udivdi3
.extern __umoddi3

.macro CHECK64 reg_lo, reg_hi, imm_lo, imm_hi
    li t5, \imm_lo
    bne \reg_lo, t5, fail
    li t5, \imm_hi
    bne \reg_hi, t5, fail
.endm

_start:
    li sp, 0x00002000

    # Case 1: 0xFEDCBA9876543210 / 0x0000000012345678
    li a0, 0x76543210
    li a1, 0xFEDCBA98
    li a2, 0x12345678
    li a3, 0x00000000
    call __udivdi3
    CHECK64 a0, a1, 0x00000077, 0x0000000E

    li a0, 0x76543210
    li a1, 0xFEDCBA98
    li a2, 0x12345678
    li a3, 0x00000000
    call __umoddi3
    CHECK64 a0, a1, 0x00000048, 0x00000000

    # Case 2: divisor high word is non-zero, forcing the full 64-bit helper path.
    li a0, 0x9ABCDEF0
    li a1, 0x12345678
    li a2, 0x00020003
    li a3, 0x00000001
    call __udivdi3
    CHECK64 a0, a1, 0x12343210, 0x00000000

    li a0, 0x9ABCDEF0
    li a1, 0x12345678
    li a2, 0x00020003
    li a3, 0x00000001
    call __umoddi3
    CHECK64 a0, a1, 0x000048C0, 0x00000000

pass:
    li t0, 0x04
    li t1, TUBE_ADDR
    sw t0, 0(t1)
pass_loop:
    j pass_loop

fail:
    li t0, 0xFF
    li t1, TUBE_ADDR
    sw t0, 0(t1)
fail_loop:
    j fail_loop
