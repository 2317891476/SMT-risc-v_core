.section .text
.globl _start

.include "p2_mmio.inc"

_start:
    la x5, amo_word

    li x6, 0x11111111
    sw x6, 0(x5)
    lw x7, 0(x5)
    bne x7, x6, test_fail

    lr.w x8, (x5)
    bne x8, x6, test_fail

    li x9, 0x22222222
    sc.w x10, x9, (x5)
    bne x10, x0, test_fail
    lw x11, 0(x5)
    bne x11, x9, test_fail

    li x12, 0x33333333
    sc.w x13, x12, (x5)
    beq x13, x0, test_fail
    lw x14, 0(x5)
    bne x14, x9, test_fail

    li x15, 0x01020304
    amoswap.w x16, x15, (x5)
    bne x16, x9, test_fail
    lw x17, 0(x5)
    bne x17, x15, test_fail

    li x18, 1
    amoadd.w x19, x18, (x5)
    bne x19, x15, test_fail
    lw x20, 0(x5)
    li x21, 0x01020305
    bne x20, x21, test_fail

    li x22, 0x000000ff
    amoxor.w x23, x22, (x5)
    bne x23, x21, test_fail
    lw x24, 0(x5)
    li x25, 0x010203fa
    bne x24, x25, test_fail

    li x26, 0x0000000f
    amoand.w x27, x26, (x5)
    bne x27, x25, test_fail
    lw x28, 0(x5)
    li x29, 0x0000000a
    bne x28, x29, test_fail

    li x30, 0x000000f0
    amoor.w x31, x30, (x5)
    bne x31, x29, test_fail
    lw x6, 0(x5)
    li x7, 0x000000fa
    bne x6, x7, test_fail

    li x8, -5
    amomin.w x9, x8, (x5)
    bne x9, x7, test_fail
    lw x10, 0(x5)
    bne x10, x8, test_fail

    li x11, 9
    amomax.w x12, x11, (x5)
    bne x12, x8, test_fail
    lw x13, 0(x5)
    bne x13, x11, test_fail

    li x14, 0xffffffff
    amominu.w x15, x14, (x5)
    bne x15, x11, test_fail
    lw x16, 0(x5)
    bne x16, x11, test_fail

    amomaxu.w x17, x14, (x5)
    bne x17, x11, test_fail
    lw x18, 0(x5)
    bne x18, x14, test_fail

    li x19, 0x04
    li x20, TUBE_ADDR
    sw x19, 0(x20)

test_pass:
    j test_pass

test_fail:
    li x19, 0xFF
    li x20, TUBE_ADDR
    sw x19, 0(x20)
fail_loop:
    j fail_loop

.section .data
.align 2
amo_word:
    .word 0
