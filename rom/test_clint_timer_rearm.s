.section .text
.globl _start

.include "p2_mmio.inc"

# Test: CLINT timer re-arm
# Verifies:
# - one timer interrupt can be cleared and then re-armed for a second delivery
# - mcause remains correct across multiple deliveries
# - clearing mtimecmp after the second interrupt stops retriggering

_start:
    li x31, 0
    li x30, 0

    la x1, trap_handler
    csrw mtvec, x1

    li x2, 0x80
    csrrs x0, mie, x2
    li x3, 0x8
    csrrs x0, mstatus, x3

    li x4, CLINT_MTIME_LO
    lw x5, 0(x4)

    li x6, CLINT_MTIMECMP_HI
    li x7, 0xFFFFFFFF
    sw x7, 0(x6)
    li x8, CLINT_MTIMECMP_LO
    addi x9, x5, 40
    sw x9, 0(x8)
    sw x0, 0(x6)

    li x10, 1000
wait_for_first_irq:
    li x11, 1
    beq x31, x11, rearm_second_irq
    addi x10, x10, -1
    bnez x10, wait_for_first_irq
    j test_fail

rearm_second_irq:
    li x12, 0x80000007
    bne x30, x12, test_fail

    li x13, CLINT_MTIME_LO
    lw x14, 0(x13)

    li x15, CLINT_MTIMECMP_HI
    li x16, 0xFFFFFFFF
    sw x16, 0(x15)
    li x17, CLINT_MTIMECMP_LO
    addi x18, x14, 40
    sw x18, 0(x17)
    sw x0, 0(x15)

    li x10, 1000
wait_for_two_irqs:
    li x11, 2
    beq x31, x11, verify_done
    addi x10, x10, -1
    bnez x10, wait_for_two_irqs
    j test_fail

verify_done:
    li x12, 0x80000007
    bne x30, x12, test_fail

    li x13, 0x04
    li x14, TUBE_ADDR
    sw x13, 0(x14)

test_pass:
    j test_pass

test_fail:
    li x13, 0xFF
    li x14, TUBE_ADDR
    sw x13, 0(x14)
fail_loop:
    j fail_loop

trap_handler:
    csrr x30, mcause
    li x29, 0x80000007
    bne x30, x29, trap_fail

    addi x31, x31, 1

    # Clear the timer after each interrupt. Mainline code rearms the second one.
    li x28, CLINT_MTIMECMP_HI
    li x27, 0xFFFFFFFF
    sw x27, 0(x28)
    li x23, CLINT_MTIMECMP_LO
    sw x27, 0(x23)
    mret

trap_fail:
    li x20, 0xFF
    li x19, TUBE_ADDR
    sw x20, 0(x19)
trap_fail_loop:
    j trap_fail_loop
