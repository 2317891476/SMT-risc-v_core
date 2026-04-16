.include "p2_mmio.inc"

.section .text
.globl _start

.macro UART_SEND_DIRECT ch, byte_reg
    li \byte_reg, \ch
    sb \byte_reg, 0(x1)
.endm

_start:
    li x1, UART_TXDATA_ADDR
    li x3, TUBE_ADDR
    li x4, 0x04
    sb x4, 0(x3)

    UART_SEND_DIRECT 0x44, x10 # D
    UART_SEND_DIRECT 0x44, x10 # D
    UART_SEND_DIRECT 0x52, x10 # R
    UART_SEND_DIRECT 0x33, x10 # 3
    UART_SEND_DIRECT 0x20, x10 # space
    UART_SEND_DIRECT 0x44, x10 # D
    UART_SEND_DIRECT 0x49, x10 # I
    UART_SEND_DIRECT 0x52, x10 # R
    UART_SEND_DIRECT 0x45, x10 # E
    UART_SEND_DIRECT 0x43, x10 # C
    UART_SEND_DIRECT 0x54, x10 # T
    UART_SEND_DIRECT 0x20, x10 # space
    UART_SEND_DIRECT 0x50, x10 # P
    UART_SEND_DIRECT 0x41, x10 # A
    UART_SEND_DIRECT 0x53, x10 # S
    UART_SEND_DIRECT 0x53, x10 # S
    UART_SEND_DIRECT 0x0D, x10
    UART_SEND_DIRECT 0x0A, x10

spin:
    j spin
