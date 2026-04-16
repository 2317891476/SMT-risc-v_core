.include "p2_mmio.inc"

.section .text
.globl _start

.macro UART_SEND_IMM_R ch, byte_reg, status_reg
    li \byte_reg, \ch
    addi x0, x0, 0
    addi x0, x0, 0
    addi x0, x0, 0
    addi x0, x0, 0
.Luart_wait_\@:
    lw \status_reg, 0(x2)
    andi \status_reg, \status_reg, UART_STATUS_TX_BUSY_MASK
    bne \status_reg, x0, .Luart_wait_\@
    sb \byte_reg, 0(x1)
.endm

_start:
    li x1, UART_TXDATA_ADDR
    li x2, UART_STATUS_ADDR
    li x3, TUBE_ADDR
    li x4, 0x04
    sb x4, 0(x3)

    UART_SEND_IMM_R 0x44, x10, x11 # D
    UART_SEND_IMM_R 0x44, x10, x11 # D
    UART_SEND_IMM_R 0x52, x10, x11 # R
    UART_SEND_IMM_R 0x33, x10, x11 # 3
    UART_SEND_IMM_R 0x20, x10, x11 # space
    UART_SEND_IMM_R 0x45, x10, x11 # E
    UART_SEND_IMM_R 0x58, x10, x11 # X
    UART_SEND_IMM_R 0x45, x10, x11 # E
    UART_SEND_IMM_R 0x43, x10, x11 # C
    UART_SEND_IMM_R 0x20, x10, x11 # space
    UART_SEND_IMM_R 0x50, x10, x11 # P
    UART_SEND_IMM_R 0x41, x10, x11 # A
    UART_SEND_IMM_R 0x53, x10, x11 # S
    UART_SEND_IMM_R 0x53, x10, x11 # S
    UART_SEND_IMM_R 0x0D, x10, x11
    UART_SEND_IMM_R 0x0A, x10, x11

spin:
    j spin
