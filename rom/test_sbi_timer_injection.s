.section .text
.globl _start

.include "p2_mmio.inc"

# OpenSBI timer injection smoke:
# - M-mode injects supervisor timer pending (STIP) through mip[5].
# - MIDELEG delegates supervisor timer interrupt bit 5.
# - S-mode receives scause=0x80000005 and clears sip.STIP.

_start:
    li x31, 0

    la x1, s_timer_handler
    csrw stvec, x1

    li x2, 0x00000020
    csrw mideleg, x2

    # Inject STIP before entering S-mode. SIE/STIE are enabled after MRET.
    csrs mip, x2

    la x3, supervisor_entry
    csrw mepc, x3

    li x4, 0x00000880
    csrw mstatus, x4
    mret

    j test_fail

supervisor_entry:
    li x5, 0x00000020
    csrs sie, x5
    li x6, 0x00000002
    csrs sstatus, x6

    li x7, 20000
wait_irq:
    li x8, 1
    beq x31, x8, verify_done
    addi x7, x7, -1
    bnez x7, wait_irq
    j test_fail

verify_done:
    csrr x9, sip
    li x10, 0x00000020
    and x11, x9, x10
    bnez x11, test_fail

    li x12, 0x04
    li x13, TUBE_ADDR
    sw x12, 0(x13)

test_pass:
    j test_pass

test_fail:
    li x12, 0xFF
    li x13, TUBE_ADDR
    sw x12, 0(x13)
fail_loop:
    j fail_loop

s_timer_handler:
    csrr x20, scause
    li x21, 0x80000005
    bne x20, x21, trap_fail

    li x22, 0x00000020
    csrc sip, x22
    li x31, 1
    sret

trap_fail:
    li x23, 0xFF
    li x24, TUBE_ADDR
    sw x23, 0(x24)
trap_fail_loop:
    j trap_fail_loop
