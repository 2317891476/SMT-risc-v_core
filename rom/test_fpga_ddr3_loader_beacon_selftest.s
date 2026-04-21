.include "p2_mmio.inc"

.equ LOADER_STACK_TOP, 0x00000FF0
.equ CALIB_TIMEOUT_CYCLES, 25000000
.equ DDR3_STATUS_CALIB_MASK, 0x01

.equ LOADER_EVT_READY,           0x01
.equ LOADER_EVT_LOAD_START,      0x02
.equ LOADER_EVT_BLOCK_ACK,       0x11
.equ LOADER_EA_EVT_HDR_B0_RX,    0x31
.equ LOADER_EA_EVT_HDR_B1_RX,    0x32
.equ LOADER_EA_EVT_HDR_B2_RX,    0x33
.equ LOADER_EA_EVT_HDR_B3_RX,    0x34
.equ LOADER_EA_EVT_HDR_MAGIC_OK, 0x35
.equ LOADER_EA_EVT_IDLE_OK,      0x36
.equ LOADER_EA_EVT_TRAIN_START,  0x37
.equ LOADER_EA_EVT_TRAIN_DONE,   0x38
.equ LOADER_EA_EVT_FLUSH_DONE,   0x39
.equ LOADER_EA_EVT_HEADER_ENTER, 0x3A
.equ LOADER_EVT_CAL_FAIL,        0xE0
.equ LOADER_EVT_SUMMARY,         0xF0

.section .text
.globl _start

_start:
    li sp, LOADER_STACK_TOP
    li x31, UART_TXDATA_ADDR
    li x30, UART_STATUS_ADDR
    li x28, UART_CTRL_ADDR
    li x27, TUBE_ADDR
    li x26, DDR3_STATUS_ADDR

    li x24, CALIB_TIMEOUT_CYCLES
poll_calib:
    lw x6, 0(x26)
    andi x5, x6, DDR3_STATUS_CALIB_MASK
    bne x5, x0, calib_done
    addi x24, x24, -1
    bne x24, x0, poll_calib
    li x10, 0x00E0
    jal ra, emit_event
    j fail_spin

calib_done:
    li x10, 0xA101
    jal ra, emit_event
    li x10, 0xB236
    jal ra, emit_event
    li x10, 0xC337
    jal ra, emit_event
    li x10, 0x1438
    jal ra, emit_event
    li x10, 0x0539
    jal ra, emit_event
    li x10, 0xD63A
    jal ra, emit_event
    li x10, 0x4231
    jal ra, emit_event
    li x10, 0x4D32
    jal ra, emit_event
    li x10, 0x4B33
    jal ra, emit_event
    li x10, 0x3134
    jal ra, emit_event
    li x10, 0xE735
    jal ra, emit_event
    li x10, 0xF802
    jal ra, emit_event
    li x10, 0x0011
    jal ra, emit_event
    li x10, 0x0FF0
    li x5, DEBUG_BEACON_EVT_ADDR
    fence iorw, iorw
    sw x10, 0(x5)
    fence iorw, iorw
    li x6, 8192
final_summary_delay:
    addi x6, x6, -1
    bne x6, x0, final_summary_delay

success_spin:
    j success_spin

emit_event:
    li x5, DEBUG_BEACON_EVT_ADDR
    fence iorw, iorw
    sw x10, 0(x5)
    fence iorw, iorw
    li x6, 8192
emit_event_delay:
    addi x6, x6, -1
    bne x6, x0, emit_event_delay
    jalr x0, 0(ra)

fail_spin:
    j fail_spin

.balign 4
.org 0x800
thread1_spin:
    j thread1_spin
