.section .text
.globl _start

.include "p2_mmio.inc"

.macro CHECK_EQ reg, imm
    li t6, \imm
    bne \reg, t6, fail
.endm

_start:
    # Basic unsigned divide/remainder.
    li t0, 100
    li t1, 10
    divu t2, t0, t1
    CHECK_EQ t2, 10
    remu t3, t0, t1
    CHECK_EQ t3, 0

    # Signed divide with positive dividend / negative divisor.
    li t0, 100
    li t1, -5
    div t2, t0, t1
    CHECK_EQ t2, -20
    rem t3, t0, t1
    CHECK_EQ t3, 0

    # Signed divide with negative dividend.
    li t0, -100
    li t1, 7
    div t2, t0, t1
    CHECK_EQ t2, -14
    rem t3, t0, t1
    CHECK_EQ t3, -2

    # Signed divide with both operands negative.
    li t0, -100
    li t1, -7
    div t2, t0, t1
    CHECK_EQ t2, 14
    rem t3, t0, t1
    CHECK_EQ t3, -2

    # Unsigned non-even case.
    li t0, 7
    li t1, 2
    divu t2, t0, t1
    CHECK_EQ t2, 3
    remu t3, t0, t1
    CHECK_EQ t3, 1

    # Signed overflow case: 0x80000000 / -1.
    li t0, 0x80000000
    li t1, -1
    div t2, t0, t1
    li t4, 0x80000000
    bne t2, t4, fail
    rem t3, t0, t1
    CHECK_EQ t3, 0

    # Divide-by-zero behavior.
    li t0, 0x12345678
    li t1, 0
    div t2, t0, t1
    CHECK_EQ t2, -1
    rem t3, t0, t1
    li t4, 0x12345678
    bne t3, t4, fail

    li t0, 0x89ABCDEF
    li t1, 0
    divu t2, t0, t1
    CHECK_EQ t2, -1
    remu t3, t0, t1
    li t4, 0x89ABCDEF
    bne t3, t4, fail

    # Back-to-back dependent chain through DIVU -> ADDI -> REMU -> ADDI.
    li t0, 84
    li t1, 7
    divu s0, t0, t1
    addi s1, s0, -2
    remu s2, s1, t1
    addi s3, s2, 5
    CHECK_EQ s3, 8

    # Signed dependency chain: quotient immediately feeds another remainder.
    li t0, -81
    li t1, 9
    div s0, t0, t1
    rem s1, s0, t1
    CHECK_EQ s1, 0

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
