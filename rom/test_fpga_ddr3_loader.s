.include "p2_mmio.inc"

.equ LOADER_STACK_TOP, 0x00000FF0
.equ CALIB_TIMEOUT_CYCLES, 25000000
.equ BMK1_MAGIC_LE, 0x314B4D42
#ifdef SIM_FAST_STORE_DRAIN
.equ STORE_DRAIN_DELAY_CYCLES, 256
.equ STORE_DRAIN_DELAY_PER_BYTE_SHIFT, 4
#else
.equ STORE_DRAIN_DELAY_CYCLES, 32768
.equ STORE_DRAIN_DELAY_PER_BYTE_SHIFT, 10
#endif
.equ LOADER_ACK_BYTE, 0x06

.section .text
.globl _start

_start:
    li sp, LOADER_STACK_TOP
    li x31, UART_TXDATA_ADDR
    li x30, UART_STATUS_ADDR
    li x29, UART_RXDATA_ADDR
    li x28, UART_CTRL_ADDR
    li x27, TUBE_ADDR

    li x5, 0x1F
    sw x5, 0(x28)
    li x5, 0x03
    sw x5, 0(x28)
    li x5, 0x21
    sb x5, 0(x27)

    la x10, msg_boot
    jal ra, send_string

    li x26, DDR3_STATUS_ADDR
    li x25, CALIB_TIMEOUT_CYCLES
poll_calib:
    lw x5, 0(x26)
    andi x5, x5, 1
    bne x5, x0, calib_done
    addi x25, x25, -1
    bne x25, x0, poll_calib
    la x10, msg_cal_fail
    jal ra, send_string
    li x5, 0xF1
    sb x5, 0(x27)
calib_fail_spin:
    j calib_fail_spin

calib_done:
    li x5, 0x22
    sb x5, 0(x27)
    la x10, msg_ready
    jal ra, send_string

    jal ra, recv_u32
    li x5, BMK1_MAGIC_LE
    bne x10, x5, bad_magic
    jal ra, recv_u32
    mv x20, x10              # load address
    jal ra, recv_u32
    mv x21, x10              # entry
    jal ra, recv_u32
    mv x22, x10              # payload size
    jal ra, recv_u32
    mv x23, x10              # expected checksum

    la x10, msg_load_start
    jal ra, send_string
    li x5, 0x23
    sb x5, 0(x27)

    mv x24, x0               # byte offset
    mv x18, x0               # write checksum
    mv x16, x20              # current DDR3 write address
    mv x13, x0               # packed word
    mv x14, x0               # byte index in packed word
load_loop:
    beq x24, x22, load_done
    jal ra, recv_byte
    add x18, x18, x10
    mv x8, x10
    slli x15, x14, 3
    sll x8, x8, x15
    or x13, x13, x8
    addi x14, x14, 1
    addi x24, x24, 1
    li x15, 4
    bne x14, x15, load_loop
    sw x13, 0(x16)
    li x10, LOADER_ACK_BYTE
    jal ra, send_char
    addi x16, x16, 4
    mv x13, x0
    mv x14, x0
    j load_loop

load_done:
    beq x14, x0, load_done_no_tail
    sw x13, 0(x16)
    li x10, LOADER_ACK_BYTE
    jal ra, send_char
load_done_no_tail:
    li x5, 0x24
    sb x5, 0(x27)
    li x24, STORE_DRAIN_DELAY_CYCLES
    slli x15, x22, STORE_DRAIN_DELAY_PER_BYTE_SHIFT
    add x24, x24, x15
store_drain_delay:
    addi x24, x24, -1
    bne x24, x0, store_drain_delay
    li x5, 0x25
    sb x5, 0(x27)
    mv x24, x0               # verified byte count
    mv x19, x0               # readback checksum
    mv x16, x20              # current DDR3 read address
readback_word_loop:
    beq x24, x22, readback_done
    lw x7, 0(x16)
    li x5, 0x26
    sb x5, 0(x27)
    li x14, 0
readback_byte_loop:
    beq x24, x22, readback_done
    andi x8, x7, 0xFF
    add x19, x19, x8
    srli x7, x7, 8
    addi x24, x24, 1
    addi x14, x14, 1
    li x15, 4
    bne x14, x15, readback_byte_loop
    addi x16, x16, 4
    j readback_word_loop

readback_done:
    bne x19, x18, readback_fail
    la x10, msg_read_ok
    jal ra, send_string
    li x5, 0x27
    sb x5, 0(x27)
    la x10, msg_load_ok
    jal ra, send_string
    la x10, msg_jump
    jal ra, send_string
    jalr x0, 0(x21)

bad_magic:
    la x10, msg_bad_magic
    jal ra, send_string
    li x5, 0xE1
    sb x5, 0(x27)
    j fail_spin

checksum_fail:
    la x10, msg_checksum_fail
    jal ra, send_string
    li x5, 0xE2
    sb x5, 0(x27)
    j fail_spin

readback_fail:
    la x10, msg_readback_fail
    jal ra, send_string
    mv x10, x18
    jal ra, print_hex32
    la x10, msg_readback_fail_sep
    jal ra, send_string
    mv x10, x19
    jal ra, print_hex32
    la x10, msg_newline
    jal ra, send_string
    li x5, 0xE3
    sb x5, 0(x27)
    j fail_spin

fail_spin:
    j fail_spin

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
    andi x14, x14, 0x0F
    addi x11, x14, 0x30
    li x12, 0x3A
    blt x11, x12, print_hex32_emit
    addi x11, x11, 7
print_hex32_emit:
    mv x10, x11
    jal ra, send_char
    addi x13, x13, -4
    bge x13, x0, print_hex32_loop
    mv ra, x16
    jalr x0, 0(ra)

recv_byte:
    lw x6, 0(x30)
    andi x6, x6, UART_STATUS_RX_VALID_MASK
    beq x6, x0, recv_byte
    lw x10, 0(x29)
    andi x10, x10, 0xFF
    jalr x0, 0(ra)

recv_u32:
recv_u32_b0_wait:
    lw x6, 0(x30)
    andi x6, x6, UART_STATUS_RX_VALID_MASK
    beq x6, x0, recv_u32_b0_wait
    lw x12, 0(x29)
    andi x12, x12, 0xFF
recv_u32_b1_wait:
    lw x6, 0(x30)
    andi x6, x6, UART_STATUS_RX_VALID_MASK
    beq x6, x0, recv_u32_b1_wait
    lw x10, 0(x29)
    andi x10, x10, 0xFF
    slli x10, x10, 8
    or x12, x12, x10
recv_u32_b2_wait:
    lw x6, 0(x30)
    andi x6, x6, UART_STATUS_RX_VALID_MASK
    beq x6, x0, recv_u32_b2_wait
    lw x10, 0(x29)
    andi x10, x10, 0xFF
    slli x10, x10, 16
    or x12, x12, x10
recv_u32_b3_wait:
    lw x6, 0(x30)
    andi x6, x6, UART_STATUS_RX_VALID_MASK
    beq x6, x0, recv_u32_b3_wait
    lw x10, 0(x29)
    andi x10, x10, 0xFF
    slli x10, x10, 24
    or x10, x12, x10
    jalr x0, 0(ra)

msg_boot:
    .asciz "BENCH LOADER\r\n"
msg_ready:
    .asciz "BOOT DDR3 READY\r\n"
msg_cal_fail:
    .asciz "CAL FAIL\r\n"
msg_load_start:
    .asciz "LOAD START\r\n"
msg_load_ok:
    .asciz "LOAD OK\r\n"
msg_read_ok:
    .asciz "READ OK\r\n"
msg_jump:
    .asciz "JUMP DDR3\r\n"
msg_bad_magic:
    .asciz "BAD MAGIC\r\n"
msg_checksum_fail:
    .asciz "LOAD BAD CHECKSUM\r\n"
msg_readback_fail:
    .asciz "LOAD BAD READ W="
msg_readback_fail_sep:
    .asciz " R="
msg_newline:
    .asciz "\r\n"

.balign 4
.org 0x800
thread1_spin:
    .rept 448
    nop
    .endr
    j thread1_spin
