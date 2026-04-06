.include "p2_mmio.inc"

.section .text
.globl _start

_start:
    li x1, UART_TXDATA_ADDR
    li x2, UART_STATUS_ADDR
    li x3, UART_RXDATA_ADDR
    li x4, UART_CTRL_ADDR
    li x5, TUBE_ADDR
    li x6, (UART_CTRL_TX_EN_MASK | UART_CTRL_RX_EN_MASK)
    sw x6, 0(x4)
    addi x0, x0, 0
    addi x0, x0, 0
    addi x0, x0, 0
    addi x0, x0, 0

wait_rx:
    lw x7, 0(x2)
    addi x0, x0, 0
    addi x0, x0, 0
    andi x7, x7, UART_STATUS_RX_VALID_MASK
    addi x0, x0, 0
    addi x0, x0, 0
    beq x7, x0, wait_rx

    lw x8, 0(x3)
    addi x0, x0, 0
    addi x0, x0, 0

wait_tx:
    lw x9, 0(x2)
    addi x0, x0, 0
    addi x0, x0, 0
    andi x9, x9, UART_STATUS_TX_BUSY_MASK
    addi x0, x0, 0
    addi x0, x0, 0
    bne x9, x0, wait_tx

    sb x8, 0(x1)
    addi x0, x0, 0
    addi x0, x0, 0

wait_tx_done:
    lw x9, 0(x2)
    addi x0, x0, 0
    addi x0, x0, 0
    andi x9, x9, UART_STATUS_TX_BUSY_MASK
    addi x0, x0, 0
    addi x0, x0, 0
    bne x9, x0, wait_tx_done

    li x10, 0x04
    sb x10, 0(x5)

done:
    j done
