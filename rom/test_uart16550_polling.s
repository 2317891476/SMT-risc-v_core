.section .text
.globl _start

.include "p2_mmio.inc"

_start:
    li x1, UART16550_LCR_ADDR
    li x2, UART16550_FCR_ADDR
    li x3, UART16550_THR_ADDR
    li x4, UART16550_LSR_ADDR
    li x5, UART16550_RBR_ADDR
    li x6, UART16550_SCR_ADDR
    li x7, TUBE_ADDR
    li x8, UART16550_IER_ADDR

    li x9, 0x03
    sb x9, 0(x1)
    li x9, 0x06
    sb x9, 0(x2)

    li x9, 0x5A
    sb x9, 0(x6)
    lbu x10, 0(x6)
    bne x10, x9, test_fail

    lbu x10, 0(x4)
    andi x11, x10, UART16550_LSR_THRE_MASK
    beq x11, x0, test_fail

    li x9, 0x80
    sb x9, 0(x1)
    li x9, 0x34
    sb x9, 0(x3)
    li x9, 0x12
    sb x9, 0(x8)
    lbu x10, 0(x3)
    li x11, 0x34
    bne x10, x11, test_fail
    lbu x10, 0(x8)
    li x11, 0x12
    bne x10, x11, test_fail

    li x9, 0x03
    sb x9, 0(x1)
    li x9, 0x07
    sb x9, 0(x8)
    lbu x10, 0(x8)
    bne x10, x9, test_fail
    sb x0, 0(x8)

    li x12, 20000
wait_rx:
    lbu x10, 0(x4)
    andi x11, x10, UART16550_LSR_DR_MASK
    bne x11, x0, got_rx
    addi x12, x12, -1
    bne x12, x0, wait_rx
    j test_fail

got_rx:
    lbu x10, 0(x5)
    li x11, 0xA5
    bne x10, x11, test_fail
    lbu x10, 0(x4)
    andi x11, x10, UART16550_LSR_DR_MASK
    bne x11, x0, test_fail

    li x10, 0x55
    sb x10, 0(x3)

test_pass:
    li x10, 0x04
    sw x10, 0(x7)
pass_loop:
    j pass_loop

test_fail:
    li x10, 0xFF
    sw x10, 0(x7)
fail_loop:
    j fail_loop
