.include "p2_mmio.inc"

.equ LOADER_STACK_TOP, 0x00000FF0
.equ STAGING_BUF_BASE, 0x00001800
.equ CALIB_TIMEOUT_CYCLES, 25000000
.equ BLOCK_CHECKSUM_BYTES, 64
.equ TRAINING_MIN_ACCEPT, 16
.equ TRAINING_MAX_ACCEPT, 32
.equ TRAINING_EXTRA_ACCEPT, 16
.equ TRAINING_TOTAL_LIMIT, 64
.equ IDLE_POLL_SHORT, 256
.equ IDLE_POLL_LONG,  512
.equ BMK1_MAGIC_B0, 0x42
.equ BMK1_MAGIC_B1, 0x4D
.equ BMK1_MAGIC_B2, 0x4B
.equ BMK1_MAGIC_B3, 0x31

.equ LOADER_ACK_BYTE, 0x06
.equ LOADER_BLOCK_ACK_BYTE, 0x17
.equ LOADER_BLOCK_NACK_BYTE, 0x15

.equ DDR3_STATUS_CALIB_MASK, 0x01

.equ LOADER_EA_SUM_READY,           0x01
.equ LOADER_EA_SUM_HDR_MAGIC_OK,    0x02
.equ LOADER_EA_SUM_LOAD_START,      0x04
.equ LOADER_EA_SUM_FIRST_BLOCK_ACK, 0x08
.equ LOADER_SUM_ANY_BAD,            0x80

.equ LOADER_EVT_READY,               0x01
.equ LOADER_EVT_LOAD_START,          0x02
.equ LOADER_EVT_BLOCK_ACK,           0x11
.equ LOADER_EVT_BLOCK_NACK,          0x12
.equ LOADER_EA_EVT_HDR_B0_RX,        0x31
.equ LOADER_EA_EVT_HDR_B1_RX,        0x32
.equ LOADER_EA_EVT_HDR_B2_RX,        0x33
.equ LOADER_EA_EVT_HDR_B3_RX,        0x34
.equ LOADER_EA_EVT_HDR_MAGIC_OK,     0x35
.equ LOADER_EA_EVT_IDLE_OK,          0x36
.equ LOADER_EA_EVT_TRAIN_START,      0x37
.equ LOADER_EA_EVT_TRAIN_DONE,       0x38
.equ LOADER_EA_EVT_FLUSH_DONE,       0x39
.equ LOADER_EA_EVT_HEADER_ENTER,     0x3A
.equ LOADER_EVT_CAL_FAIL,            0xE0
.equ LOADER_EVT_BAD_MAGIC,           0xE1
.equ LOADER_EVT_CHECKSUM_FAIL,       0xE2
.equ LOADER_EVT_RX_OVERRUN,          0xE5
.equ LOADER_EVT_RX_FRAME_ERR,        0xE6
.equ LOADER_EVT_SIZE_TOO_BIG,        0xE8
.equ LOADER_EA_EVT_TRAIN_TIMEOUT,    0xE9
.equ LOADER_EA_EVT_FLUSH_TIMEOUT,    0xEA
.equ LOADER_EVT_TRAP,                0xEF
.equ LOADER_EVT_SUMMARY,             0xF0

.equ FLUSH_TOTAL_LIMIT, 64
.equ FLUSH_IDLE_LIMIT,  1024

.section .text
.globl _start

_start:
    li sp, LOADER_STACK_TOP
    mv x3, x0
    li x31, UART_TXDATA_ADDR
    li x30, UART_STATUS_ADDR
    li x29, UART_RXDATA_ADDR
    li x28, UART_CTRL_ADDR
    li x27, TUBE_ADDR
    li x26, DDR3_STATUS_ADDR
    mv x25, x0

    li x5, 0x1F
    sw x5, 0(x28)
    li x5, 0x03
    sw x5, 0(x28)
    la x5, trap_unexpected
    .word 0x30529073              # csrw mtvec, x5
    .word 0x30401073              # csrw mie, x0
    li x5, 0x8
    .word 0x3002B073              # csrrc x0, mstatus, x5
    li x5, 0x21
    sb x5, 0(x27)

    li x24, CALIB_TIMEOUT_CYCLES
poll_calib:
    lw x6, 0(x26)
    andi x5, x6, DDR3_STATUS_CALIB_MASK
    bne x5, x0, calib_done
    addi x24, x24, -1
    bne x24, x0, poll_calib
    ori x25, x25, LOADER_SUM_ANY_BAD
    andi x7, x6, 0xFF
    slli x10, x7, 8
    ori x10, x10, LOADER_EVT_CAL_FAIL
    jal ra, emit_event
    jal ra, emit_summary
    li x5, 0xF1
    sb x5, 0(x27)
fail_spin:
    j fail_spin

calib_done:
    li x5, 0x22
    sb x5, 0(x27)
    ori x25, x25, LOADER_EA_SUM_READY
    addi x3, x3, 1
    andi x7, x3, 0xFF
    slli x10, x7, 8
    ori x10, x10, LOADER_EVT_READY
    jal ra, emit_event

    mv x9, x0                       # pending header byte valid
    jal ra, wait_uart_idle_long
    jal ra, recv_training_window

    jal ra, recv_header_byte
    andi x4, x10, 0xFF
    jal ra, recv_header_byte
    andi x5, x10, 0xFF
    jal ra, recv_header_byte
    andi x6, x10, 0xFF
    jal ra, recv_header_byte
    andi x7, x10, 0xFF

    slli x10, x4, 8
    ori x10, x10, LOADER_EA_EVT_HDR_B0_RX
    jal ra, emit_event
    slli x10, x5, 8
    ori x10, x10, LOADER_EA_EVT_HDR_B1_RX
    jal ra, emit_event
    slli x10, x6, 8
    ori x10, x10, LOADER_EA_EVT_HDR_B2_RX
    jal ra, emit_event
    slli x10, x7, 8
    ori x10, x10, LOADER_EA_EVT_HDR_B3_RX
    jal ra, emit_event

    li x23, 0
    li x24, BMK1_MAGIC_B0
    bne x4, x24, bad_magic
    li x23, 1
    li x24, BMK1_MAGIC_B1
    bne x5, x24, bad_magic
    li x23, 2
    li x24, BMK1_MAGIC_B2
    bne x6, x24, bad_magic
    li x23, 3
    li x24, BMK1_MAGIC_B3
    bne x7, x24, bad_magic

    ori x25, x25, LOADER_EA_SUM_HDR_MAGIC_OK
    li x10, LOADER_EA_EVT_HDR_MAGIC_OK
    jal ra, emit_event

    jal ra, recv_u32
    mv x20, x10                     # load address
    jal ra, recv_u32
    mv x21, x10                     # entry
    jal ra, recv_u32
    mv x22, x10                     # payload size
    jal ra, recv_u32
    mv x18, x10                     # expected checksum

    li x5, BLOCK_CHECKSUM_BYTES
    beq x22, x5, payload_size_ok
    ori x25, x25, LOADER_SUM_ANY_BAD
    andi x7, x22, 0xFF
    slli x10, x7, 8
    ori x10, x10, LOADER_EVT_SIZE_TOO_BIG
    jal ra, emit_event
    jal ra, emit_summary
    li x5, 0xE8
    sb x5, 0(x27)
    j fail_spin

payload_size_ok:
    ori x25, x25, LOADER_EA_SUM_LOAD_START
    li x10, LOADER_EVT_LOAD_START
    jal ra, emit_event
    li x5, 0x23
    sb x5, 0(x27)

    li x16, STAGING_BUF_BASE
    mv x17, x0                      # accepted bytes
    mv x19, x0                      # block checksum
    mv x13, x0                      # packed word
    mv x14, x0                      # byte index in packed word

recv_block_loop:
    li x5, BLOCK_CHECKSUM_BYTES
    beq x17, x5, recv_block_done
    jal ra, recv_byte
    add x19, x19, x10
    mv x8, x10
    slli x15, x14, 3
    sll x8, x8, x15
    or x13, x13, x8
    addi x14, x14, 1
    addi x17, x17, 1
    li x15, 4
    bne x14, x15, recv_block_loop
    sw x13, 0(x16)
    addi x16, x16, 4
    mv x13, x0
    mv x14, x0
    li x10, LOADER_ACK_BYTE
    jal ra, send_char
    j recv_block_loop

recv_block_done:
    beq x14, x0, recv_block_tail_done
    sw x13, 0(x16)
    addi x16, x16, 4
    mv x13, x0
    mv x14, x0
    li x10, LOADER_ACK_BYTE
    jal ra, send_char

recv_block_tail_done:
    jal ra, recv_u32
    mv x24, x10                     # host block checksum
    li x10, LOADER_ACK_BYTE
    jal ra, send_char
    bne x24, x19, checksum_fail

    li x10, LOADER_BLOCK_ACK_BYTE
    jal ra, send_char
    ori x25, x25, LOADER_EA_SUM_FIRST_BLOCK_ACK
    li x10, LOADER_EVT_BLOCK_ACK
    jal ra, emit_event
    jal ra, emit_summary
    li x5, 0x24
    sb x5, 0(x27)
success_spin:
    j success_spin

wait_uart_idle_long:
    mv x12, ra
    li x13, IDLE_POLL_LONG
wait_uart_idle_long_loop:
    fence iorw, iorw
    lw x6, 0(x30)
    andi x5, x6, UART_STATUS_RX_OVERRUN_MASK
    bne x5, x0, wait_uart_idle_long_clear
    andi x5, x6, UART_STATUS_RX_FRAME_ERR_MASK
    bne x5, x0, wait_uart_idle_long_clear
    andi x5, x6, UART_STATUS_RX_VALID_MASK
    beq x5, x0, wait_uart_idle_long_quiet
    j wait_uart_idle_long_done
wait_uart_idle_long_clear:
    jal ra, clear_uart_rx_flags
    li x13, IDLE_POLL_LONG
    j wait_uart_idle_long_loop
wait_uart_idle_long_quiet:
    addi x13, x13, -1
    bne x13, x0, wait_uart_idle_long_loop
wait_uart_idle_long_done:
    mv ra, x12
    jalr x0, 0(ra)

recv_training_window:
    mv x12, ra
    li x13, TRAINING_MIN_ACCEPT
    li x14, TRAINING_EXTRA_ACCEPT
    li x16, TRAINING_TOTAL_LIMIT
    mv x17, x0
recv_training_window_loop:
    beq x16, x0, recv_training_timeout
    addi x16, x16, -1
    jal ra, recv_byte_relaxed
    andi x7, x10, 0xFF
    li x15, 0x55
    bne x7, x15, recv_training_window_non55
    addi x17, x17, 1
    bne x13, x0, recv_training_window_dec_min
    bne x14, x0, recv_training_window_dec_extra
    j recv_training_window_loop
recv_training_window_dec_min:
    addi x13, x13, -1
    j recv_training_window_loop
recv_training_window_dec_extra:
    addi x14, x14, -1
    j recv_training_window_loop
recv_training_window_non55:
    bne x13, x0, recv_training_window_loop
    mv x8, x7
    li x9, 1
    mv ra, x12
    jalr x0, 0(ra)

recv_training_timeout:
    andi x7, x17, 0xFF
    slli x10, x7, 8
    ori x10, x10, LOADER_EA_EVT_TRAIN_TIMEOUT
    jal ra, emit_event
    j bad_magic

flush_uart_to_header:
    mv x12, ra
    mv x17, x0
    li x18, FLUSH_TOTAL_LIMIT
    li x19, FLUSH_IDLE_LIMIT
    li x13, IDLE_POLL_SHORT
flush_uart_to_header_loop:
    beq x18, x0, flush_uart_timeout
    beq x19, x0, flush_uart_timeout
    bne x9, x0, flush_uart_pending_byte
    fence iorw, iorw
    lw x6, 0(x30)
    andi x5, x6, UART_STATUS_RX_OVERRUN_MASK
    bne x5, x0, flush_uart_clear
    andi x5, x6, UART_STATUS_RX_FRAME_ERR_MASK
    bne x5, x0, flush_uart_clear
    andi x5, x6, UART_STATUS_RX_VALID_MASK
    beq x5, x0, flush_uart_quiet
    lw x10, 0(x29)
    andi x8, x10, 0xFF
    li x9, 1
    li x13, IDLE_POLL_SHORT
    j flush_uart_pending_byte
flush_uart_clear:
    jal ra, clear_uart_rx_flags
    li x13, IDLE_POLL_SHORT
    addi x19, x19, -1
    j flush_uart_to_header_loop
flush_uart_quiet:
    addi x13, x13, -1
    addi x19, x19, -1
    bne x13, x0, flush_uart_to_header_loop
    mv ra, x12
    jalr x0, 0(ra)
flush_uart_pending_byte:
    mv x7, x8
    jal ra, is_discardable_sync_byte
    beq x5, x0, flush_uart_done
    mv x9, x0
    addi x17, x17, 1
    addi x18, x18, -1
    li x13, IDLE_POLL_SHORT
    j flush_uart_to_header_loop
flush_uart_done:
    mv ra, x12
    jalr x0, 0(ra)

flush_uart_timeout:
    andi x7, x17, 0xFF
    slli x10, x7, 8
    ori x10, x10, LOADER_EA_EVT_FLUSH_TIMEOUT
    jal ra, emit_event
    jal ra, emit_summary
    li x5, 0xEA
    sb x5, 0(x27)
    j fail_spin

recv_header_byte:
    mv x12, ra
    bne x9, x0, recv_magic_byte_pending
    jal ra, recv_byte
    j recv_magic_byte_emit
recv_magic_byte_pending:
    mv x10, x8
    mv x9, x0
recv_magic_byte_emit:
    andi x10, x10, 0xFF
    mv ra, x12
    jalr x0, 0(ra)

bad_magic:
    ori x25, x25, LOADER_SUM_ANY_BAD
    andi x7, x23, 0xFF
    slli x10, x7, 8
    ori x10, x10, LOADER_EVT_BAD_MAGIC
    jal ra, emit_event
    jal ra, emit_summary
    li x5, 0xE1
    sb x5, 0(x27)
    j fail_spin

checksum_fail:
    ori x25, x25, LOADER_SUM_ANY_BAD
    li x7, 0x00
    slli x10, x7, 8
    ori x10, x10, LOADER_EVT_CHECKSUM_FAIL
    jal ra, emit_event
    li x10, LOADER_BLOCK_NACK_BYTE
    jal ra, send_char
    li x10, LOADER_EVT_BLOCK_NACK
    jal ra, emit_event
    jal ra, emit_summary
    li x5, 0xE2
    sb x5, 0(x27)
    j fail_spin

emit_event:
    li x5, DEBUG_BEACON_EVT_ADDR
    sw x10, 0(x5)
    jalr x0, 0(ra)

emit_summary:
    mv x7, ra
    slli x10, x25, 8
    ori x10, x10, LOADER_EVT_SUMMARY
    jal ra, emit_event
    mv ra, x7
    jalr x0, 0(ra)

send_char:
send_char_wait:
    lw x6, 0(x30)
    andi x6, x6, UART_STATUS_TX_BUSY_MASK
    bne x6, x0, send_char_wait
    sb x10, 0(x31)
    jalr x0, 0(ra)

recv_byte:
recv_byte_poll:
    fence iorw, iorw
    lw x6, 0(x30)
    addi x0, x0, 0
    addi x0, x0, 0
    andi x5, x6, UART_STATUS_RX_OVERRUN_MASK
    bne x5, x0, rx_overrun_fail
    addi x0, x0, 0
    andi x5, x6, UART_STATUS_RX_FRAME_ERR_MASK
    bne x5, x0, rx_frame_err_fail
    addi x0, x0, 0
    andi x6, x6, UART_STATUS_RX_VALID_MASK
    addi x0, x0, 0
    beq x6, x0, recv_byte_poll
    fence iorw, iorw
    lw x10, 0(x29)
    addi x0, x0, 0
    addi x0, x0, 0
    andi x10, x10, 0xFF
    fence iorw, iorw
    jalr x0, 0(ra)

recv_byte_relaxed:
recv_byte_relaxed_poll:
    fence iorw, iorw
    lw x6, 0(x30)
    andi x5, x6, UART_STATUS_RX_OVERRUN_MASK
    bne x5, x0, recv_byte_relaxed_clear
    andi x5, x6, UART_STATUS_RX_FRAME_ERR_MASK
    bne x5, x0, recv_byte_relaxed_clear
    andi x5, x6, UART_STATUS_RX_VALID_MASK
    beq x5, x0, recv_byte_relaxed_poll
    lw x10, 0(x29)
    andi x10, x10, 0xFF
    fence iorw, iorw
    jalr x0, 0(ra)
recv_byte_relaxed_clear:
    jal ra, clear_uart_rx_flags
    j recv_byte_relaxed_poll

clear_uart_rx_flags:
    li x5, UART_CTRL_TX_EN_MASK | UART_CTRL_RX_EN_MASK | UART_CTRL_CLR_RX_OVERRUN_MASK | UART_CTRL_CLR_RX_FRAME_ERR_MASK
    sw x5, 0(x28)
    li x5, UART_CTRL_TX_EN_MASK | UART_CTRL_RX_EN_MASK
    sw x5, 0(x28)
    jalr x0, 0(ra)

is_discardable_sync_byte:
    li x5, 1
    li x15, 0x55
    beq x7, x15, is_discardable_sync_byte_ret
    li x15, 0x00
    beq x7, x15, is_discardable_sync_byte_ret
    li x15, 0x01
    beq x7, x15, is_discardable_sync_byte_ret
    li x15, 0x11
    beq x7, x15, is_discardable_sync_byte_ret
    li x15, 0x40
    beq x7, x15, is_discardable_sync_byte_ret
    li x15, 0x80
    beq x7, x15, is_discardable_sync_byte_ret
    li x15, 0x81
    beq x7, x15, is_discardable_sync_byte_ret
    li x15, 0x8A
    beq x7, x15, is_discardable_sync_byte_ret
    li x15, 0xF0
    beq x7, x15, is_discardable_sync_byte_ret
    li x5, 0
is_discardable_sync_byte_ret:
    jalr x0, 0(ra)

recv_u32:
    mv x11, ra
    jal ra, recv_byte
    mv x12, x10
    jal ra, recv_byte
    slli x10, x10, 8
    or x12, x12, x10
    jal ra, recv_byte
    slli x10, x10, 16
    or x12, x12, x10
    jal ra, recv_byte
    slli x10, x10, 24
    or x10, x12, x10
    mv ra, x11
    jalr x0, 0(ra)

rx_overrun_fail:
    ori x25, x25, LOADER_SUM_ANY_BAD
    andi x7, x6, 0xFF
    slli x10, x7, 8
    ori x10, x10, LOADER_EVT_RX_OVERRUN
    jal ra, emit_event
    jal ra, emit_summary
    li x5, 0xE4
    sb x5, 0(x27)
    j fail_spin

rx_frame_err_fail:
    ori x25, x25, LOADER_SUM_ANY_BAD
    andi x7, x6, 0xFF
    slli x10, x7, 8
    ori x10, x10, LOADER_EVT_RX_FRAME_ERR
    jal ra, emit_event
    jal ra, emit_summary
    li x5, 0xE5
    sb x5, 0(x27)
    j fail_spin

trap_unexpected:
    ori x25, x25, LOADER_SUM_ANY_BAD
    .word 0x342023F3              # csrr x7, mcause
    andi x7, x7, 0xFF
    slli x10, x7, 8
    ori x10, x10, LOADER_EVT_TRAP
    jal ra, emit_event
    jal ra, emit_summary
    li x5, 0xEE
    sb x5, 0(x27)
trap_unexpected_spin:
    j trap_unexpected_spin

.balign 4
.org 0x800
thread1_spin:
    j thread1_spin
