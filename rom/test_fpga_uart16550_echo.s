.include "p2_mmio.inc"

.section .text
.globl _start

_start:
    li x1, UART16550_THR_ADDR
    li x2, UART16550_LSR_ADDR
    li x3, UART16550_RBR_ADDR
    li x4, UART16550_FCR_ADDR
    li x5, TUBE_ADDR
    li x11, 0

    li x6, 0x06
    sb x6, 0(x4)                  # clear RX/TX FIFOs
    li x6, 0x21
    sb x6, 0(x5)

#ifdef BOARD_BUILD
board_ready_tx_wait:
    lbu x7, 0(x2)
    andi x7, x7, UART16550_LSR_THRE_MASK
    beq x7, x0, board_ready_tx_wait
    li x6, 'R'
    sb x6, 0(x1)
#endif

wait_rx:
    lbu x7, 0(x2)
    andi x6, x7, UART16550_LSR_DR_MASK
    beq x6, x0, wait_rx

    lbu x8, 0(x3)

wait_tx:
    lbu x9, 0(x2)
    andi x9, x9, UART16550_LSR_THRE_MASK
    beq x9, x0, wait_tx

    sb x8, 0(x1)

wait_tx_done:
    lbu x9, 0(x2)
    andi x9, x9, UART16550_LSR_TEMT_MASK
    beq x9, x0, wait_tx_done

    bne x11, x0, wait_rx
    li x10, 0x04
    sb x10, 0(x5)
    li x11, 1
    j wait_rx
