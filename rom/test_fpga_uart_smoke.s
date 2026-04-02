.include "p2_mmio.inc"

.section .text
.globl _start

_start:
    li x1, UART_TXDATA_ADDR
    li x2, UART_STATUS_ADDR
    li x3, TUBE_ADDR

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
    li x11, 0x4D
    jal x15, send_char
    li x11, 0x4D
    jal x15, send_char
    li x11, 0x49
    jal x15, send_char
    li x11, 0x4F
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

uart_drain:
    lw x12, 0(x2)
    andi x12, x12, 1
    bne x12, x0, uart_drain

    li x13, 0x04
    sw x13, 0(x3)

pass_loop:
    j pass_loop

send_char:
    lw x12, 0(x2)
    andi x12, x12, 1
    bne x12, x0, send_char

    sb x11, 0(x1)
    jalr x0, 0(x15)
