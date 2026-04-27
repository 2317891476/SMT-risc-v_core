.include "p2_mmio.inc"

.equ TRANSPORT_STACK_TOP, 0x00000FF0
.equ BMK1_MAGIC_LE, 0x314B4D42
.equ LOADER_ACK_BYTE, 0x06

.section .text
.globl _start

_start:
    li sp, TRANSPORT_STACK_TOP
    li x31, UART_TXDATA_ADDR
    li x30, UART_STATUS_ADDR
    li x29, UART_RXDATA_ADDR
    li x28, UART_CTRL_ADDR
    li x27, TUBE_ADDR

    li x5, 0x1F
    sw x5, 0(x28)
    li x5, 0x03
    sw x5, 0(x28)
    li x5, 0x31
    sb x5, 0(x27)

    la x10, msg_boot
    jal ra, send_string

session_wait:
    li x5, 0x32
    sb x5, 0(x27)

    jal ra, recv_u32
    li x5, BMK1_MAGIC_LE
    bne x10, x5, bad_magic

    jal ra, recv_u32          # load_addr (ignored in transport-only mode)
    jal ra, recv_u32          # entry (ignored in transport-only mode)
    jal ra, recv_u32
    mv x22, x10               # payload size
    jal ra, recv_u32
    mv x23, x10               # expected checksum

    la x10, msg_load_start
    jal ra, send_string
    li x5, 0x33
    sb x5, 0(x27)

    mv x24, x0                # byte count
    mv x18, x0                # checksum
    mv x19, x0                # expected byte value
load_loop:
    beq x24, x22, load_done
    jal ra, recv_byte
    mv x20, x10               # actual byte value
    bne x20, x19, bad_byte_fail
    add x18, x18, x20
    addi x19, x19, 1
    andi x19, x19, 0xFF
    addi x24, x24, 1
    andi x6, x24, 3
    bne x6, x0, load_loop
    li x10, LOADER_ACK_BYTE
    jal ra, send_char
    j load_loop

load_done:
    andi x6, x22, 3
    beq x6, x0, load_done_no_tail
    li x10, LOADER_ACK_BYTE
    jal ra, send_char
load_done_no_tail:
    la x10, msg_read_ok
    jal ra, send_string
    bne x18, x23, checksum_fail

    li x5, 0x04
    sb x5, 0(x27)
    la x10, msg_load_ok
    jal ra, send_string
    j session_wait

bad_magic:
    la x10, msg_bad_magic
    jal ra, send_string
    li x5, 0xE1
    sb x5, 0(x27)
    j fail_spin

checksum_fail:
    la x10, msg_checksum_fail
    jal ra, send_string
    mv x10, x23
    jal ra, print_hex32
    la x10, msg_sep
    jal ra, send_string
    mv x10, x18
    jal ra, print_hex32
    la x10, msg_newline
    jal ra, send_string
    li x5, 0xE2
    sb x5, 0(x27)
    j fail_spin

bad_byte_fail:
    la x10, msg_bad_byte_idx
    jal ra, send_string
    mv x10, x24
    jal ra, print_hex32
    la x10, msg_bad_byte_exp
    jal ra, send_string
    mv x10, x19
    jal ra, print_hex32
    la x10, msg_bad_byte_act
    jal ra, send_string
    mv x10, x20
    jal ra, print_hex32
    la x10, msg_bad_byte_status
    jal ra, send_string
    jal ra, print_uart_status_line
    li x5, 0xE5
    sb x5, 0(x27)
    j fail_spin

recv_byte:
recv_byte_wait:
    lw x6, 0(x30)
    andi x7, x6, UART_STATUS_RX_OVERRUN_MASK
    bne x7, x0, rx_overrun_fail
    andi x7, x6, UART_STATUS_RX_FRAME_ERR_MASK
    bne x7, x0, rx_frame_fail
    andi x7, x6, UART_STATUS_RX_VALID_MASK
    beq x7, x0, recv_byte_wait
    lw x10, 0(x29)
    andi x10, x10, 0xFF
    jalr x0, 0(ra)

recv_u32:
    mv x17, ra
    jal ra, recv_byte
    mv x11, x10
    jal ra, recv_byte
    slli x10, x10, 8
    or x11, x11, x10
    jal ra, recv_byte
    slli x10, x10, 16
    or x11, x11, x10
    jal ra, recv_byte
    slli x10, x10, 24
    or x10, x11, x10
    jalr x0, 0(x17)

send_char:
send_char_wait:
    lw x6, 0(x30)
    andi x6, x6, UART_STATUS_TX_BUSY_MASK
    bne x6, x0, send_char_wait
    sb x10, 0(x31)
    jalr x0, 0(ra)

send_string:
    mv x11, x10
send_string_loop:
    lbu x10, 0(x11)
    beq x10, x0, send_string_done
send_string_wait:
    lw x6, 0(x30)
    andi x6, x6, UART_STATUS_TX_BUSY_MASK
    bne x6, x0, send_string_wait
    sb x10, 0(x31)
    addi x11, x11, 1
    j send_string_loop
send_string_done:
    jalr x0, 0(ra)

print_hex32:
    mv x16, ra
    mv x17, x10
    li x13, 28
print_hex32_loop:
    srl x14, x17, x13
    andi x14, x14, 0xF
    li x15, 10
    blt x14, x15, print_hex32_digit
    addi x14, x14, 55
    j print_hex32_emit
print_hex32_digit:
    addi x14, x14, 48
print_hex32_emit:
    mv x10, x14
    jal ra, send_char
    addi x13, x13, -4
    bgez x13, print_hex32_loop
    jalr x0, 0(x16)

print_uart_status_line:
    mv x16, ra
    lw x10, 0(x30)
    jal ra, print_hex32
    la x10, msg_newline
    jal ra, send_string
    jalr x0, 0(x16)

rx_overrun_fail:
    la x10, msg_rx_overrun
    jal ra, send_string
    jal ra, print_uart_status_line
    li x5, 0xE3
    sb x5, 0(x27)
    j fail_spin

rx_frame_fail:
    la x10, msg_rx_frame
    jal ra, send_string
    jal ra, print_uart_status_line
    li x5, 0xE4
    sb x5, 0(x27)
    j fail_spin

fail_spin:
    j fail_spin

.section .rodata
msg_boot:
    .asciz "BOOT TRANSPORT READY\r\n"
msg_load_start:
    .asciz "LOAD START\r\n"
msg_read_ok:
    .asciz "READ OK\r\n"
msg_load_ok:
    .asciz "LOAD OK\r\n"
msg_bad_magic:
    .asciz "BAD MAGIC\r\n"
msg_checksum_fail:
    .asciz "LOAD BAD CHECKSUM E="
msg_bad_byte_idx:
    .asciz "BAD_BYTE IDX="
msg_bad_byte_exp:
    .asciz " EXP="
msg_bad_byte_act:
    .asciz " ACT="
msg_bad_byte_status:
    .asciz " ST="
msg_sep:
    .asciz " R="
msg_newline:
    .asciz "\r\n"
msg_rx_overrun:
    .asciz "RX OVERRUN ST="
msg_rx_frame:
    .asciz "RX FRAME ERR ST="

.balign 4
.org 0x800
thread1_spin:
    .rept 448
    nop
    .endr
    j thread1_spin
