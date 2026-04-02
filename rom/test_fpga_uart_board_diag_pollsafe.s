.include "p2_mmio.inc"

.section .text
.globl _start

_start:
    li x1, UART_TXDATA_ADDR
    li x2, UART_STATUS_ADDR
    li x3, TUBE_ADDR
    li x4, 0x04
    li x13, 0x00

send_loop:
    li x11, 0x55
    jal x15, send_char
    li x11, 0x41
    jal x15, send_char
    li x11, 0x52
    jal x15, send_char
    li x11, 0x54
    jal x15, send_char
    li x11, 0x20
    jal x15, send_char
    li x11, 0x44
    jal x15, send_char
    li x11, 0x49
    jal x15, send_char
    li x11, 0x41
    jal x15, send_char
    li x11, 0x47
    jal x15, send_char
    li x11, 0x20
    jal x15, send_char
    li x11, 0x50
    jal x15, send_char
    li x11, 0x41
    jal x15, send_char
    li x11, 0x53
    jal x15, send_char
    li x11, 0x53
    jal x15, send_char
    li x11, 0x0D
    jal x15, send_char
    li x11, 0x0A
    jal x15, send_char
    j send_loop

send_char:
poll_uart:
    lw x12, 0(x2)
    addi x0, x0, 0
    andi x12, x12, 1
    addi x0, x0, 0
    bne x12, x0, poll_uart

    sb x11, 0(x1)
    bne x13, x0, send_char_ret
    sb x4, 0(x3)
    li x13, 0x01

send_char_ret:
    jalr x0, 0(x15)
