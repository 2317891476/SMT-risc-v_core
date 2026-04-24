.section .text
.globl _start

.include "p2_mmio.inc"

# Wrong-path CSR and MRET must remain blocked behind an unresolved branch.

_start:
    li x1, 0
    csrw mscratch, x1

    la x2, mret_bad
    csrw mepc, x2
    li x3, 0x55

    beq x0, x0, target
    csrw mscratch, x3
    mret

mret_bad:
    j test_fail

target:
    csrr x4, mscratch
    bne x4, x0, test_fail

    li x5, 0x04
    li x6, TUBE_ADDR
    sw x5, 0(x6)

test_pass:
    j test_pass

test_fail:
    li x5, 0xFF
    li x6, TUBE_ADDR
    sw x5, 0(x6)
fail_loop:
    j fail_loop
