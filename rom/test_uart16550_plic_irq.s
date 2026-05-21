.section .text
.globl _start

.include "p2_mmio.inc"

_start:
    li x31, 0
    li x30, 0

    la x1, trap_handler
    csrw mtvec, x1

    li x2, PLIC_PRIORITY2
    li x3, 1
    sw x3, 0(x2)

    li x4, PLIC_ENABLE
    li x5, 4
    sw x5, 0(x4)

    li x6, PLIC_THRESHOLD
    sw x0, 0(x6)

    li x7, UART16550_FCR_ADDR
    li x8, 0x06
    sb x8, 0(x7)

    li x7, UART16550_IER_ADDR
    li x8, UART16550_IER_RDA_MASK
    sb x8, 0(x7)

    li x9, 0x800
    csrrs x0, mie, x9
    li x10, 0x8
    csrrs x0, mstatus, x10

    li x11, 20000
wait_irq:
    li x12, 1
    beq x31, x12, verify_done
    addi x11, x11, -1
    bne x11, x0, wait_irq
    j test_fail

verify_done:
    li x13, PLIC_PENDING
    lw x14, 0(x13)
    bnez x14, test_fail

    li x15, 0x04
    li x16, TUBE_ADDR
    sw x15, 0(x16)

test_pass:
    j test_pass

test_fail:
    li x15, 0xFF
    li x16, TUBE_ADDR
    sw x15, 0(x16)
fail_loop:
    j fail_loop

trap_handler:
    csrr x20, mcause
    li x21, 0x8000000B
    bne x20, x21, trap_fail

    li x22, PLIC_CLAIM_COMPLETE
    lw x23, 0(x22)
    li x24, 2
    bne x23, x24, trap_fail

    li x25, UART16550_RBR_ADDR
    lbu x30, 0(x25)
    li x24, 0x3C
    bne x30, x24, trap_fail
    li x31, 1
    sw x23, 0(x22)
    fence iorw, iorw
    li x26, PLIC_PENDING
    lw x27, 0(x26)
    bnez x27, trap_fail
    li x26, 0x04
    li x27, TUBE_ADDR
    sw x26, 0(x27)
trap_pass_loop:
    j trap_pass_loop

trap_fail:
    li x26, 0xFF
    li x27, TUBE_ADDR
    sw x26, 0(x27)
trap_fail_loop:
    j trap_fail_loop
