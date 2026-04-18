.include "p2_mmio.inc"

.equ BRIDGE_STACK_TOP,          0x00000FF0
.equ DDR3_BASE_ADDR,            0x80000000
#ifdef SIM_FAST_BRIDGE_STRESS
.equ BRIDGE_BLOCK_COUNT,        1
.equ BRIDGE_WORDS_PER_BLOCK,    4
#else
.equ BRIDGE_BLOCK_COUNT,        4
.equ BRIDGE_WORDS_PER_BLOCK,    16
#endif
.equ CALIB_TIMEOUT_CYCLES,      25000000
.equ DRAIN_STATUS_TIMEOUT,      25000000
.equ DDR3_STATUS_CALIB_MASK,    0x01
.equ DDR3_STATUS_DRAIN_READY,   0x07

.section .text
.globl _start

_start:
    li sp, BRIDGE_STACK_TOP
    li x31, UART_TXDATA_ADDR
    li x30, UART_STATUS_ADDR
    li x29, UART_CTRL_ADDR
    li x28, TUBE_ADDR
    li x27, DDR3_STATUS_ADDR
    la x5, trap_unexpected
    csrw mtvec, x5
    csrw mie, x0
    li x5, 0x08
    csrrc x0, mstatus, x5

    li x5, 0x1F
    sw x5, 0(x29)
    li x5, 0x03
    sw x5, 0(x29)
    li x5, 0x31
    sb x5, 0(x28)

    la x10, msg_boot
    jal ra, send_string

    li x24, CALIB_TIMEOUT_CYCLES
poll_calib:
    lw x5, 0(x27)
    andi x6, x5, DDR3_STATUS_CALIB_MASK
    bne x6, x0, calib_done
    addi x24, x24, -1
    bne x24, x0, poll_calib
    la x10, msg_cal_fail
    jal ra, send_string
    mv x10, x5
    jal ra, print_hex32
    la x10, msg_newline
    jal ra, send_string
    li x5, 0xE1
    sb x5, 0(x28)
calib_fail_spin:
    j calib_fail_spin

calib_done:
    la x10, msg_ready
    jal ra, send_string
    li x24, 0                # loop counter

bridge_loop:
    li x5, 0x32
    sb x5, 0(x28)
    li x20, DDR3_BASE_ADDR
    li x21, 0                # block idx

write_block_loop:
    li x6, BRIDGE_BLOCK_COUNT
    beq x21, x6, writes_done
    li x22, 0                # word idx
write_word_loop:
    li x6, BRIDGE_WORDS_PER_BLOCK
    beq x22, x6, write_next_block
    mv x10, x24
    mv x11, x21
    mv x12, x22
    jal ra, make_pattern
    sw x10, 0(x20)
    addi x20, x20, 4
    addi x22, x22, 1
    j write_word_loop

write_next_block:
    addi x21, x21, 1
    j write_block_loop

writes_done:
    fence iorw, iorw
    li x25, DRAIN_STATUS_TIMEOUT
wait_drain_ready:
    lw x5, 0(x27)
    andi x6, x5, DDR3_STATUS_DRAIN_READY
    li x7, DDR3_STATUS_DRAIN_READY
    beq x6, x7, drain_ready
    addi x25, x25, -1
    bne x25, x0, wait_drain_ready
    la x10, msg_drain_timeout
    jal ra, send_string
    mv x10, x5
    jal ra, print_hex32
    la x10, msg_newline
    jal ra, send_string
    li x5, 0xE2
    sb x5, 0(x28)
drain_fail_spin:
    j drain_fail_spin

drain_ready:
    li x20, DDR3_BASE_ADDR
    lw x0, 0(x20)            # serialized read fence through bridge
    li x20, DDR3_BASE_ADDR
    li x21, 0

read_block_loop:
    li x6, BRIDGE_BLOCK_COUNT
    beq x21, x6, bridge_pass
    li x22, 0
read_word_loop:
    li x6, BRIDGE_WORDS_PER_BLOCK
    beq x22, x6, read_next_block
    mv x10, x24
    mv x11, x21
    mv x12, x22
    jal ra, make_pattern
    mv x13, x10              # expected
    lw x14, 0(x20)           # actual
    bne x13, x14, bridge_bad
    addi x20, x20, 4
    addi x22, x22, 1
    j read_word_loop

read_next_block:
    addi x21, x21, 1
    j read_block_loop

bridge_pass:
    li x5, 0x04
    sb x5, 0(x28)
    jal ra, send_bridge_ok
#ifdef SIM_FAST_BRIDGE_STRESS
bridge_pass_spin:
    j bridge_pass_spin
#else
    addi x24, x24, 1
    j bridge_loop
#endif

bridge_bad:
    mv x8, x13
    mv x9, x14
    lw x12, 0(x27)
    la x10, msg_bad_blk
    jal ra, send_string
    mv x10, x21
    jal ra, print_hex32
    la x10, msg_bad_addr
    jal ra, send_string
    mv x10, x20
    jal ra, print_hex32
    la x10, msg_bad_exp
    jal ra, send_string
    mv x10, x8
    jal ra, print_hex32
    la x10, msg_bad_act
    jal ra, send_string
    mv x10, x9
    jal ra, print_hex32
    la x10, msg_bad_status
    jal ra, send_string
    mv x10, x12
    jal ra, print_hex32
    la x10, msg_newline
    jal ra, send_string
    li x5, 0xE3
    sb x5, 0(x28)
bridge_bad_spin:
    j bridge_bad_spin

trap_unexpected:
    li x5, 0xEE
    sb x5, 0(x28)
trap_unexpected_spin:
    j trap_unexpected_spin

make_pattern:
    lui x13, 0xA5000
    slli x14, x11, 16
    slli x15, x12, 8
    andi x16, x10, 0xFF
    or x13, x13, x14
    or x13, x13, x15
    or x10, x13, x16
    jalr x0, 0(ra)

send_char:
send_char_wait:
    lw x6, 0(x30)
    andi x6, x6, UART_STATUS_TX_BUSY_MASK
    bne x6, x0, send_char_wait
    sb x10, 0(x31)
    jalr x0, 0(ra)

send_string:
    mv x18, ra
    mv x11, x10
send_string_loop:
    lbu x10, 0(x11)
    beq x10, x0, send_string_done
    jal ra, send_char
    addi x11, x11, 1
    j send_string_loop
send_string_done:
    mv ra, x18
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

send_bridge_ok:
    mv x19, ra
    li x10, 0x42            # B
    jal ra, send_char
    li x10, 0x52            # R
    jal ra, send_char
    li x10, 0x49            # I
    jal ra, send_char
    li x10, 0x44            # D
    jal ra, send_char
    li x10, 0x47            # G
    jal ra, send_char
    li x10, 0x45            # E
    jal ra, send_char
    li x10, 0x20            # space
    jal ra, send_char
    li x10, 0x4F            # O
    jal ra, send_char
    li x10, 0x4B            # K
    jal ra, send_char
    li x10, 0x0D
    jal ra, send_char
    li x10, 0x0A
    jal ra, send_char
    mv ra, x19
    jalr x0, 0(ra)

msg_boot:
    .asciz "BRIDGE BOOT\r\n"
msg_ready:
    .asciz "BRIDGE READY\r\n"
msg_bad_blk:
    .asciz "BRIDGE BAD BLK="
msg_bad_addr:
    .asciz " A="
msg_bad_exp:
    .asciz " E="
msg_bad_act:
    .asciz " R="
msg_bad_status:
    .asciz " ST="
msg_cal_fail:
    .asciz "BRIDGE CAL FAIL ST="
msg_drain_timeout:
    .asciz "BRIDGE DRAIN TIMEOUT ST="
msg_newline:
    .asciz "\r\n"

.balign 4
.org 0x800
thread1_spin:
    .rept 448
    nop
    .endr
    j thread1_spin
