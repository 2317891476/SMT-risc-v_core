.include "p2_mmio.inc"

.equ PRELOAD_STACK_TOP, 0x00000FF0
.equ CALIB_TIMEOUT_CYCLES, 25000000
.equ DRAIN_STATUS_TIMEOUT_CYCLES, 25000000
.equ DDR3_LOAD_ADDR, 0x80000000
.equ DDR3_STATUS_CALIB_MASK, 0x01
.equ DDR3_STATUS_SB_EMPTY_MASK, 0x02
.equ DDR3_STATUS_BRIDGE_IDLE_MASK, 0x04
.equ DDR3_STATUS_DRAIN_READY_MASK, 0x07

.section .text
.globl _start

_start:
    li sp, PRELOAD_STACK_TOP
    li x31, UART_TXDATA_ADDR
    li x30, UART_STATUS_ADDR
    li x28, UART_CTRL_ADDR
    li x27, TUBE_ADDR
    li x26, DDR3_STATUS_ADDR

    li x5, 0x1F
    sw x5, 0(x28)
    li x5, 0x03
    sw x5, 0(x28)
    li x5, 0x31
    sb x5, 0(x27)

    li x24, CALIB_TIMEOUT_CYCLES
poll_calib:
    lw x6, 0(x26)
    andi x5, x6, DDR3_STATUS_CALIB_MASK
    bne x5, x0, calib_done
    addi x24, x24, -1
    bne x24, x0, poll_calib
    la x10, msg_cal_fail
    jal ra, puts
calib_fail_spin:
    j calib_fail_spin

calib_done:
    la x10, msg_preload
    jal ra, puts
    li x5, 0x32
    sb x5, 0(x27)

    la x18, payload_start
    la x19, payload_end
    li x20, DDR3_LOAD_ADDR
copy_loop:
    bgeu x18, x19, copy_done
    lw x8, 0(x18)
    sw x8, 0(x20)
    fence iorw, iorw
    jal ra, wait_drain_ready
    addi x18, x18, 4
    addi x20, x20, 4
    j copy_loop

copy_done:
    li x5, 0x33
    sb x5, 0(x27)
    la x10, msg_jump
    jal ra, puts
    .word 0x0000100f
    li x5, DDR3_LOAD_ADDR
    jalr x0, 0(x5)

wait_drain_ready:
    mv x9, ra
    li x6, DRAIN_STATUS_TIMEOUT_CYCLES
    li x7, DDR3_STATUS_DRAIN_READY_MASK
wait_drain_ready_loop:
    lw x5, 0(x26)
    and x5, x5, x7
    beq x5, x7, wait_drain_ready_done
    addi x6, x6, -1
    bne x6, x0, wait_drain_ready_loop
    la x10, msg_drain_fail
    jal ra, puts
drain_fail_spin:
    j drain_fail_spin
wait_drain_ready_done:
    mv ra, x9
    jalr x0, 0(ra)

send_char:
send_char_wait:
    lw x6, 0(x30)
    andi x6, x6, UART_STATUS_TX_BUSY_MASK
    bne x6, x0, send_char_wait
    sb x10, 0(x31)
    jalr x0, 0(ra)

puts:
    mv x12, x10
    mv x13, ra
puts_loop:
    lbu x10, 0(x12)
    beq x10, x0, puts_done
    jal ra, send_char
    addi x12, x12, 1
    j puts_loop
puts_done:
    mv ra, x13
    jalr x0, 0(ra)

.balign 4
msg_preload:
    .asciz "PRELOAD DHRYSTONE\r\n"
msg_jump:
    .asciz "PRELOAD JUMP\r\n"
msg_cal_fail:
    .asciz "PRELOAD CAL FAIL\r\n"
msg_drain_fail:
    .asciz "PRELOAD DRAIN FAIL\r\n"

.balign 4
payload_start:
    .incbin "../build/fpga_benchmark_ddr3/payload_manifests/dhrystone_smoke.bin"
payload_end:

.balign 4
.org 0x3FFC
preload_end_word:
    .word 0
