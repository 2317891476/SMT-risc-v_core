.include "p2_mmio.inc"

.section .text
.globl _start

_start:
    li x1, UART_TXDATA_ADDR
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
    sb x11, 0(x1)
    bne x13, x0, delay_only
    sb x4, 0(x3)
    li x13, 0x01

delay_only:
    li x12, 5000
delay_loop:
    addi x12, x12, -1
    bne x12, x0, delay_loop
    jalr x0, 0(x15)
