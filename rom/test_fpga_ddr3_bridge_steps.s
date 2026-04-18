.include "p2_mmio.inc"

.equ BRIDGE_STACK_TOP,          0x00000FF0
.equ DDR3_BASE_ADDR,            0x80000000
#ifdef SIM_FAST_BRIDGE_STEPS
.equ STEP1_ITERATIONS,          4
.equ STEP2_ITERATIONS,          3
.equ STEP3_ITERATIONS,          2
#else
.equ STEP1_ITERATIONS,          32
.equ STEP2_ITERATIONS,          16
.equ STEP3_ITERATIONS,          16
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

#ifndef SIM_FAST_BRIDGE_STEPS
    la x10, msg_boot
    jal ra, send_string
#endif

    li x25, CALIB_TIMEOUT_CYCLES
poll_calib:
    lw x22, 0(x27)
    andi x6, x22, DDR3_STATUS_CALIB_MASK
    bne x6, x0, calib_done
    addi x25, x25, -1
    bne x25, x0, poll_calib
    la x10, msg_cal_fail
    jal ra, send_string
    mv x10, x22
    jal ra, print_hex32
    jal ra, send_crlf
    li x5, 0xE1
    sb x5, 0(x28)
calib_fail_spin:
    j calib_fail_spin

calib_done:
    la x10, msg_ready
    jal ra, send_string

    jal ra, run_step1
    jal ra, run_step2
    li x5, 2
    jal ra, run_step3_words
    li x5, 4
    jal ra, run_step3_words

    li x5, 0x04
    sb x5, 0(x28)
    la x10, msg_all_ok
    jal ra, send_string
bridge_all_ok_spin:
    j bridge_all_ok_spin

run_step1:
    addi sp, sp, -4
    sw ra, 0(sp)
    li x26, 1
    li x6, 0x41
    sb x6, 0(x28)
    li x5, 1
    jal ra, emit_step_start
    li x21, 0
step1_loop:
    li x6, STEP1_ITERATIONS
    beq x21, x6, step1_done

    li x7, DDR3_BASE_ADDR
    li x10, 1
    mv x11, x21
    li x12, 0
    jal ra, make_value
    mv x23, x7
    mv x24, x10
    sw x10, 0(x7)

    li x5, 1
    jal ra, wait_drain_ready

    li x7, DDR3_BASE_ADDR
    lw x0, 0(x7)
    li x10, 1
    mv x11, x21
    li x12, 0
    jal ra, make_value
    mv x8, x10
    lw x9, 0(x7)
    bne x8, x9, step1_fail

    addi x21, x21, 1
    j step1_loop

step1_done:
    li x5, 1
    jal ra, emit_step_ok
    lw ra, 0(sp)
    addi sp, sp, 4
    jalr x0, 0(ra)

step1_fail:
    li x5, 1
    j emit_bad_and_halt

run_step2:
    addi sp, sp, -4
    sw ra, 0(sp)
    li x26, 2
    li x6, 0x42
    sb x6, 0(x28)
    li x5, 2
    jal ra, emit_step_start
    li x21, 0
step2_loop:
    li x6, STEP2_ITERATIONS
    beq x21, x6, step2_done

    li x7, DDR3_BASE_ADDR
    li x10, 2
    mv x11, x21
    li x12, 0
    jal ra, make_value
    mv x23, x7
    mv x24, x10
    sw x10, 0(x7)

    li x7, DDR3_BASE_ADDR + 4
    li x10, 2
    mv x11, x21
    li x12, 1
    jal ra, make_value
    mv x23, x7
    mv x24, x10
    sw x10, 0(x7)

    li x5, 2
    jal ra, wait_drain_ready

    li x7, DDR3_BASE_ADDR
    lw x0, 0(x7)

    li x7, DDR3_BASE_ADDR
    li x10, 2
    mv x11, x21
    li x12, 0
    jal ra, make_value
    mv x8, x10
    lw x9, 0(x7)
    bne x8, x9, step2_fail

    li x7, DDR3_BASE_ADDR + 4
    li x10, 2
    mv x11, x21
    li x12, 1
    jal ra, make_value
    mv x8, x10
    lw x9, 0(x7)
    bne x8, x9, step2_fail

    addi x21, x21, 1
    j step2_loop

step2_done:
    li x5, 2
    jal ra, emit_step_ok
    lw ra, 0(sp)
    addi sp, sp, 4
    jalr x0, 0(ra)

step2_fail:
    li x5, 2
    j emit_bad_and_halt

run_step3_words:
    addi sp, sp, -4
    sw ra, 0(sp)
    mv x19, x5
    li x26, 3
    li x6, 0x43
    sb x6, 0(x28)
    mv x5, x19
    jal ra, emit_step_start
    li x21, 0
step3_round_loop:
    li x6, STEP3_ITERATIONS
    beq x21, x6, step3_done

    li x6, 0
step3_write_loop:
    beq x6, x19, step3_writes_done
    slli x7, x6, 2
    li x20, DDR3_BASE_ADDR
    add x7, x20, x7
    li x10, 3
    mv x11, x21
    mv x12, x6
    jal ra, make_value
    mv x23, x7
    mv x24, x10
    sw x10, 0(x7)
    addi x6, x6, 1
    j step3_write_loop

step3_writes_done:
    mv x5, x19
    jal ra, wait_drain_ready

    li x7, DDR3_BASE_ADDR
    lw x0, 0(x7)

    li x6, 0
step3_read_loop:
    beq x6, x19, step3_round_done
    slli x7, x6, 2
    li x20, DDR3_BASE_ADDR
    add x7, x20, x7
    li x10, 3
    mv x11, x21
    mv x12, x6
    jal ra, make_value
    mv x8, x10
    lw x9, 0(x7)
    bne x8, x9, step3_fail
    addi x6, x6, 1
    j step3_read_loop

step3_round_done:
    addi x21, x21, 1
    j step3_round_loop

step3_done:
    mv x5, x19
    jal ra, emit_step_ok
    lw ra, 0(sp)
    addi sp, sp, 4
    jalr x0, 0(ra)

step3_fail:
    mv x5, x19
    j emit_bad_and_halt

wait_drain_ready:
    li x25, DRAIN_STATUS_TIMEOUT
wait_drain_ready_loop:
    lw x22, 0(x27)
    andi x6, x22, DDR3_STATUS_DRAIN_READY
    li x7, DDR3_STATUS_DRAIN_READY
    beq x6, x7, wait_drain_ready_done
    addi x25, x25, -1
    bne x25, x0, wait_drain_ready_loop
    mv x7, x23
    li x8, 0
    li x9, 0
    j emit_bad_and_halt
wait_drain_ready_done:
    jalr x0, 0(ra)

emit_step_start:
#ifdef SIM_FAST_BRIDGE_STEPS
    jalr x0, 0(ra)
#else
    mv x20, ra
    la x10, msg_step_start
    jal ra, send_string
    mv x10, x26
    jal ra, send_digit
    la x10, msg_words
    jal ra, send_string
    mv x10, x5
    jal ra, send_digit
    jal ra, send_crlf
    mv ra, x20
    jalr x0, 0(ra)
#endif

emit_step_ok:
    mv x20, ra
    la x10, msg_step_ok
    jal ra, send_string
    mv x10, x26
    jal ra, send_digit
    la x10, msg_words
    jal ra, send_string
    mv x10, x5
    jal ra, send_digit
    jal ra, send_crlf
    mv ra, x20
    jalr x0, 0(ra)

emit_bad_and_halt:
    mv x20, x5
    lw x22, 0(x27)
    la x10, msg_step_bad
    jal ra, send_string
    mv x10, x26
    jal ra, send_digit
    la x10, msg_words
    jal ra, send_string
    mv x10, x20
    jal ra, send_digit
    la x10, msg_addr
    jal ra, send_string
    mv x10, x7
    jal ra, print_hex32
    la x10, msg_expected
    jal ra, send_string
    mv x10, x8
    jal ra, print_hex32
    la x10, msg_actual
    jal ra, send_string
    mv x10, x9
    jal ra, print_hex32
    la x10, msg_last_write_addr
    jal ra, send_string
    mv x10, x23
    jal ra, print_hex32
    la x10, msg_last_write_data
    jal ra, send_string
    mv x10, x24
    jal ra, print_hex32
    la x10, msg_drain_ready
    jal ra, send_string
    andi x6, x22, DDR3_STATUS_DRAIN_READY
    li x10, 0
    li x11, DDR3_STATUS_DRAIN_READY
    bne x6, x11, emit_bad_dr_ready
    li x10, 1
emit_bad_dr_ready:
    jal ra, send_digit
    la x10, msg_bridge_idle
    jal ra, send_string
    srli x10, x22, 2
    andi x10, x10, 1
    jal ra, send_digit
    la x10, msg_status
    jal ra, send_string
    mv x10, x22
    jal ra, print_hex32
    jal ra, send_crlf
    li x6, 0xE3
    add x6, x6, x26
    sb x6, 0(x28)
emit_bad_spin:
    j emit_bad_spin

make_value:
    lui x13, 0xA5000
    slli x14, x10, 16
    slli x15, x11, 8
    andi x16, x12, 0xFF
    or x13, x13, x14
    or x13, x13, x15
    or x10, x13, x16
    jalr x0, 0(ra)

send_digit:
    mv x17, ra
    addi x10, x10, 0x30
    jal ra, send_char
    mv ra, x17
    jalr x0, 0(ra)

send_crlf:
    mv x18, ra
    li x10, 0x0D
    jal ra, send_char
    li x10, 0x0A
    jal ra, send_char
    mv ra, x18
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

trap_unexpected:
    li x5, 0xEE
    sb x5, 0(x28)
trap_unexpected_spin:
    j trap_unexpected_spin

msg_boot:
    .asciz "BSTEP BOOT\r\n"
msg_ready:
    .asciz "BSTEP READY\r\n"
msg_step_start:
    .asciz "BSTEP START S="
msg_step_ok:
    .asciz "BSTEP OK S="
msg_step_bad:
    .asciz "BSTEP BAD S="
msg_words:
    .asciz " N="
msg_addr:
    .asciz " A="
msg_expected:
    .asciz " E="
msg_actual:
    .asciz " R="
msg_last_write_addr:
    .asciz " LW_A="
msg_last_write_data:
    .asciz " LW_D="
msg_drain_ready:
    .asciz " DR="
msg_bridge_idle:
    .asciz " ID="
msg_status:
    .asciz " ST="
msg_all_ok:
    .asciz "BSTEP ALL OK\r\n"
msg_cal_fail:
    .asciz "BSTEP CAL FAIL ST="

.balign 4
.org 0x800
thread1_spin:
    .rept 448
    nop
    .endr
    j thread1_spin
