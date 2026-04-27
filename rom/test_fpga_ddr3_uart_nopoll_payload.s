.include "p2_mmio.inc"

.section .text
.globl _start

.macro DELAY_SHORT reg
    li \reg, 2500
.Ldelay_\@:
    addi \reg, \reg, -1
    bne \reg, x0, .Ldelay_\@
.endm

.macro UART_SEND_DIRECT ch, byte_reg, delay_reg
    li \byte_reg, \ch
    sb \byte_reg, 0(x1)
    DELAY_SHORT \delay_reg
.endm

_start:
    li x1, UART_TXDATA_ADDR
    li x3, TUBE_ADDR
    li x4, 0x04
    sb x4, 0(x3)
    DELAY_SHORT x12

    UART_SEND_DIRECT 0x44, x10, x12 # D
    UART_SEND_DIRECT 0x44, x10, x12 # D
    UART_SEND_DIRECT 0x52, x10, x12 # R
    UART_SEND_DIRECT 0x33, x10, x12 # 3
    UART_SEND_DIRECT 0x20, x10, x12 # space
    UART_SEND_DIRECT 0x4E, x10, x12 # N
    UART_SEND_DIRECT 0x4F, x10, x12 # O
    UART_SEND_DIRECT 0x50, x10, x12 # P
    UART_SEND_DIRECT 0x4F, x10, x12 # O
    UART_SEND_DIRECT 0x4C, x10, x12 # L
    UART_SEND_DIRECT 0x4C, x10, x12 # L
    UART_SEND_DIRECT 0x20, x10, x12 # space
    UART_SEND_DIRECT 0x50, x10, x12 # P
    UART_SEND_DIRECT 0x41, x10, x12 # A
    UART_SEND_DIRECT 0x53, x10, x12 # S
    UART_SEND_DIRECT 0x53, x10, x12 # S
    UART_SEND_DIRECT 0x0D, x10, x12
    UART_SEND_DIRECT 0x0A, x10, x12

spin:
    j spin
