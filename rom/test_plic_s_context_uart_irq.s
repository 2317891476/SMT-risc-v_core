.section .text
.globl _start

.include "p2_mmio.inc"

# Linux bring-up interrupt smoke:
# - UART16550 source ID 2 is enabled only in PLIC S-context.
# - MIDELEG delegates supervisor external interrupt bit 9.
# - S-mode receives scause=0x80000009 and claims/completes source 2.

_start:
    li x31, 0

    la x1, s_trap_handler
    csrw stvec, x1

    li x2, PLIC_PRIORITY2
    li x3, 1
    sw x3, 0(x2)

    li x4, PLIC_S_ENABLE
    li x5, 4
    sw x5, 0(x4)

    li x6, PLIC_S_THRESHOLD
    sw x0, 0(x6)

    li x7, UART16550_FCR_ADDR
    li x8, 0x06
    sb x8, 0(x7)

    li x7, UART16550_IER_ADDR
    li x8, UART16550_IER_RDA_MASK
    sb x8, 0(x7)

    li x9, 0x00000200
    csrw mideleg, x9

    la x10, supervisor_entry
    csrw mepc, x10

    li x11, 0x00000880
    csrw mstatus, x11
    mret

    j test_fail

supervisor_entry:
    li x12, 0x00000200
    csrs sie, x12
    li x13, 0x00000002
    csrs sstatus, x13

    li x14, 50000
wait_irq:
    li x15, 1
    beq x31, x15, verify_done
    addi x14, x14, -1
    bnez x14, wait_irq
    j test_fail

verify_done:
    li x16, PLIC_PENDING
    lw x17, 0(x16)
    bnez x17, test_fail

    li x18, 0x04
    li x19, TUBE_ADDR
    sw x18, 0(x19)

test_pass:
    j test_pass

test_fail:
    li x18, 0xFF
    li x19, TUBE_ADDR
    sw x18, 0(x19)
fail_loop:
    j fail_loop

s_trap_handler:
    csrr x20, scause
    li x21, 0x80000009
    bne x20, x21, trap_fail

    li x22, PLIC_S_CLAIM_COMPLETE
    lw x23, 0(x22)
    li x24, 2
    bne x23, x24, trap_fail

    li x25, UART16550_RBR_ADDR
    lbu x26, 0(x25)
    li x27, 0x5A
    bne x26, x27, trap_fail

    sw x23, 0(x22)
    li x31, 1
    sret

trap_fail:
    li x28, 0xFF
    li x29, TUBE_ADDR
    sw x28, 0(x29)
trap_fail_loop:
    j trap_fail_loop
