.include "p2_mmio.inc"

.section .text
.globl _start

_start:
    li x20, UART_TXDATA_ADDR
    li x21, UART_STATUS_ADDR
    li x22, UART_RXDATA_ADDR
    li x23, UART_CTRL_ADDR
    li x24, TUBE_ADDR
    li x25, (UART_CTRL_TX_EN_MASK | UART_CTRL_RX_EN_MASK)
    li x26, 0x100000
    sw x25, 0(x23)

    li x10, 'R'
    jal x1, send_byte

wait_rx:
    lw x7, 0(x21)
    addi x0, x0, 0

    andi x8, x7, UART_STATUS_RX_FRAME_ERR_MASK
    bne x8, x0, handle_frame_err

    andi x8, x7, UART_STATUS_RX_OVERRUN_MASK
    bne x8, x0, handle_overrun

    andi x8, x7, UART_STATUS_RX_VALID_MASK
    bne x8, x0, handle_valid

    addi x26, x26, -1
    bne x26, x0, wait_rx

    li x26, 0x100000
    li x10, 'W'
    jal x1, send_byte
    j wait_rx

handle_frame_err:
    li x10, 'F'
    jal x1, send_byte
    li x8, (UART_CTRL_TX_EN_MASK | UART_CTRL_RX_EN_MASK | UART_CTRL_CLR_RX_FRAME_ERR_MASK)
    sw x8, 0(x23)
    li x26, 0x100000
    j wait_rx

handle_overrun:
    li x10, 'O'
    jal x1, send_byte
    li x8, (UART_CTRL_TX_EN_MASK | UART_CTRL_RX_EN_MASK | UART_CTRL_CLR_RX_OVERRUN_MASK)
    sw x8, 0(x23)
    li x26, 0x100000
    j wait_rx

handle_valid:
    lw x11, 0(x22)
    li x10, 'V'
    jal x1, send_byte
    addi x10, x11, 0
    jal x1, send_byte
    li x12, 0x04
    sb x12, 0(x24)

done:
    j done

send_byte:
wait_tx:
    lw x9, 0(x21)
    addi x0, x0, 0
    andi x9, x9, UART_STATUS_TX_BUSY_MASK
    addi x0, x0, 0
    bne x9, x0, wait_tx

    sb x10, 0(x20)
    jalr x0, 0(x1)
