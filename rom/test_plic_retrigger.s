.section .text
.globl _start

.include "p2_mmio.inc"

# Test: PLIC pending retention under threshold mask
# Verifies:
# - an external interrupt pulse becomes pending even while threshold masks it
# - lowering the threshold later delivers the already-pending interrupt
# - claim/complete clears the pending state once serviced

_start:
    li x31, 0
    li x30, 0

    la x1, trap_handler
    csrw mtvec, x1

    li x2, PLIC_PRIORITY1
    li x3, 2
    sw x3, 0(x2)

    li x4, PLIC_ENABLE
    li x5, 2
    sw x5, 0(x4)

    li x6, PLIC_THRESHOLD
    li x7, 2
    sw x7, 0(x6)        # Mask priority-1 interrupt behind threshold.

    li x7, PLIC_PENDING
    lw x8, 0(x7)
    bnez x8, test_fail

    li x9, 0x800
    csrrs x0, mie, x9
    li x10, 0x8
    csrrs x0, mstatus, x10

    # Wait long enough for the masked pulse to arrive. The handler must not run yet.
    li x11, 200
wait_masked_pending:
    bnez x31, test_fail
    addi x11, x11, -1
    bnez x11, wait_masked_pending

    lw x12, 0(x7)
    li x13, 1
    bne x12, x13, test_fail

    # Unmask the pending interrupt and verify it now gets delivered.
    sw x0, 0(x6)

    li x11, 1200
wait_for_irq:
    li x12, 1
    beq x31, x12, verify_done
    addi x11, x11, -1
    bnez x11, wait_for_irq
    j test_fail

verify_done:
    li x13, 0x8000000B
    bne x30, x13, test_fail
    li x14, PLIC_PENDING
    lw x15, 0(x14)
    bnez x15, test_fail

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

trap_handler:
    csrr x30, mcause
    li x29, 0x8000000B
    bne x30, x29, trap_fail

    li x28, PLIC_CLAIM_COMPLETE
    lw x27, 0(x28)
    li x26, 1
    bne x27, x26, trap_fail

    addi x31, x31, 1
    sw x27, 0(x28)
    mret

trap_fail:
    li x20, 0xFF
    li x19, TUBE_ADDR
    sw x20, 0(x19)
trap_fail_loop:
    j trap_fail_loop
