.include "p2_mmio.inc"

.equ LOADER_STACK_TOP, 0x00000FF0
.equ STAGING_BUF_BASE, 0x00001800
.equ STAGING_BUF_MAX_BYTES, 0x00002800
.equ CALIB_TIMEOUT_CYCLES, 25000000
.equ BMK1_MAGIC_LE, 0x314B4D42
#ifdef SIM_FAST_STORE_DRAIN
.equ STORE_DRAIN_DELAY_CYCLES, 256
.equ STORE_DRAIN_DELAY_PER_BYTE_SHIFT, 4
.equ CHUNK_STORE_SETTLE_CYCLES, 16
.equ BLOCK_REPLY_DELAY_CYCLES, 32
#else
.equ STORE_DRAIN_DELAY_CYCLES, 65536
.equ STORE_DRAIN_DELAY_PER_BYTE_SHIFT, 10
.equ CHUNK_STORE_SETTLE_CYCLES, 256
.equ BLOCK_REPLY_DELAY_CYCLES, 1024
#endif
.equ LOADER_ACK_BYTE, 0x06
.equ LOADER_BLOCK_ACK_BYTE, 0x17
.equ LOADER_BLOCK_NACK_BYTE, 0x15
.equ BLOCK_CHECKSUM_BYTES, 64
.equ DDR3_STATUS_CALIB_MASK, 0x01
.equ DDR3_STATUS_SB_EMPTY_MASK, 0x02
.equ DDR3_STATUS_BRIDGE_IDLE_MASK, 0x04
.equ DDR3_STATUS_DRAIN_READY_MASK, 0x07
.equ DRAIN_STATUS_TIMEOUT_CYCLES, 25000000

.equ LOADER_SUM_READY,      0x01
.equ LOADER_SUM_LOAD_START, 0x02
.equ LOADER_SUM_READ_OK,    0x04
.equ LOADER_SUM_LOAD_OK,    0x08
.equ LOADER_SUM_JUMP,       0x10
.equ LOADER_SUM_ANY_BAD,    0x80

.equ LOADER_EVT_READY,               0x01
.equ LOADER_EVT_LOAD_START,          0x02
.equ LOADER_EVT_BLOCK_ACK,           0x11
.equ LOADER_EVT_BLOCK_NACK,          0x12
.equ LOADER_EVT_READ_OK,             0x21
.equ LOADER_EVT_LOAD_OK,             0x22
.equ LOADER_EVT_JUMP,                0x23
.equ LOADER_EVT_CAL_FAIL,            0xE0
.equ LOADER_EVT_BAD_MAGIC,           0xE1
.equ LOADER_EVT_CHECKSUM_FAIL,       0xE2
.equ LOADER_EVT_READBACK_FAIL,       0xE3
.equ LOADER_EVT_READBACK_BLOCK_FAIL, 0xE4
.equ LOADER_EVT_RX_OVERRUN,          0xE5
.equ LOADER_EVT_RX_FRAME_ERR,        0xE6
.equ LOADER_EVT_DRAIN_TIMEOUT,       0xE7
.equ LOADER_EVT_SIZE_TOO_BIG,        0xE8
.equ LOADER_EVT_SUMMARY,             0xF0

.section .text
.globl _start

_start:
    li sp, LOADER_STACK_TOP
    li x31, UART_TXDATA_ADDR
    li x30, UART_STATUS_ADDR
    li x29, UART_RXDATA_ADDR
    li x28, UART_CTRL_ADDR
    li x27, TUBE_ADDR
    li x26, DDR3_STATUS_ADDR
    mv x25, x0               # loader summary mask

    li x5, 0x1F
    sw x5, 0(x28)
    li x5, 0x03
    sw x5, 0(x28)
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
calib_fail_spin:
    j calib_fail_spin

calib_done:
    li x5, 0x22
    sb x5, 0(x27)
    ori x25, x25, LOADER_SUM_READY
    li x10, LOADER_EVT_READY
    jal ra, emit_event

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

    li x5, STAGING_BUF_MAX_BYTES
    bgeu x5, x22, payload_size_ok
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
    ori x25, x25, LOADER_SUM_LOAD_START
    li x10, LOADER_EVT_LOAD_START
    jal ra, emit_event
    li x5, 0x23
    sb x5, 0(x27)

    mv x24, x0               # accepted byte offset
    mv x18, x0               # accepted checksum
    li x16, STAGING_BUF_BASE # current staging write address
    la x4, loader_write_block_sums
    mv x3, x0                # block index

load_block_begin:
    beq x24, x22, load_done
    sub x12, x22, x24
    li x15, BLOCK_CHECKSUM_BYTES
    bltu x12, x15, load_block_size_ready
    mv x12, x15
load_block_size_ready:
    mv x17, x16              # current block start address

load_block_retry:
    mv x9, x0                # current block checksum
    mv x11, x0               # current block byte count
    mv x13, x0               # packed word
    mv x14, x0               # byte index in packed word

load_block_recv_loop:
    beq x11, x12, load_block_done
    jal ra, recv_byte
    add x9, x9, x10
    mv x8, x10
    slli x15, x14, 3
    sll x8, x8, x15
    or x13, x13, x8
    addi x14, x14, 1
    addi x11, x11, 1
    li x15, 4
    bne x14, x15, load_block_recv_loop
    sw x13, 0(x16)
    li x6, CHUNK_STORE_SETTLE_CYCLES
chunk_store_settle_wait:
    addi x6, x6, -1
    bne x6, x0, chunk_store_settle_wait
    fence iorw, iorw
    li x10, LOADER_ACK_BYTE
    jal ra, send_char
    addi x16, x16, 4
    mv x13, x0
    mv x14, x0
    j load_block_recv_loop

load_block_done:
    beq x14, x0, load_block_tail_done
    sw x13, 0(x16)
    li x6, CHUNK_STORE_SETTLE_CYCLES
load_tail_store_settle_wait:
    addi x6, x6, -1
    bne x6, x0, load_tail_store_settle_wait
    fence iorw, iorw
    li x10, LOADER_ACK_BYTE
    jal ra, send_char
    addi x16, x16, 4

load_block_tail_done:
    mv x15, x12              # preserve block byte count
    jal ra, recv_u32
    mv x14, x10              # host block checksum
    li x10, LOADER_ACK_BYTE
    jal ra, send_char
    li x6, BLOCK_REPLY_DELAY_CYCLES
load_block_reply_delay:
    addi x6, x6, -1
    bne x6, x0, load_block_reply_delay
    bne x14, x9, load_block_nack
    sw x9, 0(x4)
    addi x4, x4, 4
    add x18, x18, x9
    add x24, x24, x15
    li x10, LOADER_BLOCK_ACK_BYTE
    jal ra, send_char
    andi x7, x3, 0xFF
    slli x10, x7, 8
    ori x10, x10, LOADER_EVT_BLOCK_ACK
    jal ra, emit_event
    addi x3, x3, 1
    j load_block_begin

load_block_nack:
    mv x16, x17
    li x10, LOADER_BLOCK_NACK_BYTE
    jal ra, send_char
    andi x7, x3, 0xFF
    slli x10, x7, 8
    ori x10, x10, LOADER_EVT_BLOCK_NACK
    jal ra, emit_event
    j load_block_retry

load_done:
load_checksum_compare:
    bne x18, x23, checksum_fail

    mv x24, x0
    li x16, STAGING_BUF_BASE
    mv x17, x20
flush_staging_loop:
    bgeu x24, x22, flush_staging_done
    lw x13, 0(x16)
    sw x13, 0(x17)
    addi x16, x16, 4
    addi x17, x17, 4
    addi x24, x24, 4
    j flush_staging_loop

flush_staging_done:
    li x5, 0x24
    sb x5, 0(x27)
    li x24, STORE_DRAIN_DELAY_CYCLES
    slli x15, x22, STORE_DRAIN_DELAY_PER_BYTE_SHIFT
    add x24, x24, x15
store_drain_delay:
    addi x24, x24, -1
    bne x24, x0, store_drain_delay

    li x24, DRAIN_STATUS_TIMEOUT_CYCLES
wait_store_drain_ready:
    lw x6, 0(x26)
    andi x5, x6, DDR3_STATUS_DRAIN_READY_MASK
    li x7, DDR3_STATUS_DRAIN_READY_MASK
    beq x5, x7, store_drain_ready
    addi x24, x24, -1
    bne x24, x0, wait_store_drain_ready
    ori x25, x25, LOADER_SUM_ANY_BAD
    andi x7, x6, 0xFF
    slli x10, x7, 8
    ori x10, x10, LOADER_EVT_DRAIN_TIMEOUT
    jal ra, emit_event
    jal ra, emit_summary
    li x5, 0xE6
    sb x5, 0(x27)
    j fail_spin

store_drain_ready:
    addi x17, x16, -4
    lw x0, 0(x17)            # serialized read fence across the DDR3 bridge
    li x5, 0x25
    sb x5, 0(x27)
    mv x24, x0               # verified byte count
    mv x19, x0               # readback checksum
    mv x16, x20              # current DDR3 read address
    la x4, loader_write_block_sums
    mv x9, x0                # current 64B read block checksum
    mv x11, x0               # current 64B read block byte count
    mv x3, x0                # readback block index

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
    add x9, x9, x8
    addi x11, x11, 1
    li x15, BLOCK_CHECKSUM_BYTES
    bne x11, x15, readback_block_checksum_done
    lw x6, 0(x4)
    bne x9, x6, readback_fail_block
    addi x4, x4, 4
    addi x3, x3, 1
    mv x9, x0
    mv x11, x0
readback_block_checksum_done:
    srli x7, x7, 8
    addi x24, x24, 1
    addi x14, x14, 1
    li x15, 4
    bne x14, x15, readback_byte_loop
    addi x16, x16, 4
    j readback_word_loop

readback_done:
    beq x11, x0, readback_done_checksums
    lw x6, 0(x4)
    bne x9, x6, readback_fail_block
readback_done_checksums:
    bne x19, x18, readback_fail

    li x5, 0x27
    sb x5, 0(x27)
    ori x25, x25, LOADER_SUM_READ_OK
    li x10, LOADER_EVT_READ_OK
    jal ra, emit_event
    ori x25, x25, LOADER_SUM_LOAD_OK
    li x10, LOADER_EVT_LOAD_OK
    jal ra, emit_event
    ori x25, x25, LOADER_SUM_JUMP
    li x10, LOADER_EVT_JUMP
    jal ra, emit_event
    jal ra, emit_summary
    jalr x0, 0(x21)

bad_magic:
    ori x25, x25, LOADER_SUM_ANY_BAD
    li x10, LOADER_EVT_BAD_MAGIC
    jal ra, emit_event
    jal ra, emit_summary
    li x5, 0xE1
    sb x5, 0(x27)
    j fail_spin

checksum_fail:
    ori x25, x25, LOADER_SUM_ANY_BAD
    li x7, 0xFF
    slli x10, x7, 8
    ori x10, x10, LOADER_EVT_CHECKSUM_FAIL
    jal ra, emit_event
    jal ra, emit_summary
    li x5, 0xE2
    sb x5, 0(x27)
    j fail_spin

readback_fail:
    ori x25, x25, LOADER_SUM_ANY_BAD
    li x7, 0xFE
    slli x10, x7, 8
    ori x10, x10, LOADER_EVT_READBACK_FAIL
    jal ra, emit_event
    jal ra, emit_summary
    li x5, 0xE3
    sb x5, 0(x27)
    j fail_spin

readback_fail_block:
    ori x25, x25, LOADER_SUM_ANY_BAD
    andi x7, x3, 0xFF
    slli x10, x7, 8
    ori x10, x10, LOADER_EVT_READBACK_BLOCK_FAIL
    jal ra, emit_event
    jal ra, emit_summary
    li x5, 0xE7
    sb x5, 0(x27)
    j fail_spin

fail_spin:
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

.balign 4
.org 0x800
thread1_spin:
    j thread1_spin

.balign 4
.org 0x1000
loader_write_block_sums:
    .space 1024
