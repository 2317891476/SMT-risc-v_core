.include "p2_mmio.inc"

.equ BRIDGE_STACK_TOP,          0x00000FF0
.equ DDR3_BASE_ADDR,            0x80000000
.equ DDR3_ADDR0,                DDR3_BASE_ADDR
.equ DDR3_ADDR1,                DDR3_BASE_ADDR + 4
.equ CALIB_TIMEOUT_CYCLES,      25000000
.equ DRAIN_STATUS_TIMEOUT,      25000000
.equ DDR3_STATUS_CALIB_MASK,    0x01
.equ DDR3_STATUS_DRAIN_READY,   0x07

.section .text
.globl _start

_start:
    csrr x6, mhartid
    bne x6, x0, thread1_spin
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

    li x6, CALIB_TIMEOUT_CYCLES
poll_calib:
    lw x22, 0(x27)
    andi x5, x22, DDR3_STATUS_CALIB_MASK
    bne x5, x0, calib_done
    addi x6, x6, -1
    bne x6, x0, poll_calib
    la x10, msg_cal_fail
    jal ra, send_string
    mv x10, x22
    jal ra, print_hex32
    jal ra, send_crlf
    li x5, 0xE0
    sb x5, 0(x28)
calib_fail_spin:
    j calib_fail_spin

calib_done:
    la x10, msg_ready
    jal ra, send_string

    jal ra, run_case1
    jal ra, run_case2
    jal ra, run_case3
    jal ra, run_case4
    jal ra, run_case5

    li x5, 0x04
    sb x5, 0(x28)
    la x10, msg_all_ok
    jal ra, send_string
all_ok_spin:
    j all_ok_spin

run_case1:
    addi sp, sp, -4
    sw ra, 0(sp)
    li x26, 1
    li x5, 0x61
    sb x5, 0(x28)
    li x23, DDR3_ADDR0
    li x24, 0x13A5C7EF
    li x21, 0
    li x20, 0
    li x19, DDR3_ADDR0
    jal ra, emit_case_start
    jal ra, wait_uart_tx_idle
    li x25, 2
    sw x24, 0(x23)
    fence iorw, iorw
    li x25, 4
    jal ra, wait_drain_ready_or_fail
    li x25, 5
    fence iorw, iorw
    mv x8, x24
    lw x9, 0(x19)
    bne x8, x9, case_compare_fail
    jal ra, emit_case_ok
    lw ra, 0(sp)
    addi sp, sp, 4
    jalr x0, 0(ra)

run_case2:
    addi sp, sp, -4
    sw ra, 0(sp)
    li x26, 2
    li x5, 0x62
    sb x5, 0(x28)
    li x23, DDR3_ADDR1
    li x24, 0xE14C82B7
    li x21, 0
    li x20, 0
    li x19, DDR3_ADDR1
    jal ra, emit_case_start
    jal ra, wait_uart_tx_idle
    li x25, 2
    sw x24, 0(x23)
    fence iorw, iorw
    li x25, 4
    jal ra, wait_drain_ready_or_fail
    li x25, 5
    fence iorw, iorw
    mv x8, x24
    lw x9, 0(x19)
    bne x8, x9, case_compare_fail
    jal ra, emit_case_ok
    lw ra, 0(sp)
    addi sp, sp, 4
    jalr x0, 0(ra)

run_case3:
    addi sp, sp, -4
    sw ra, 0(sp)
    li x26, 3
    li x5, 0x63
    sb x5, 0(x28)
    li x23, DDR3_ADDR0
    li x24, 0x5AC3F10E
    li x21, DDR3_ADDR1
    li x20, 0xC67D29B4
    li x19, DDR3_ADDR0
    jal ra, emit_case_start
    jal ra, wait_uart_tx_idle
    li x25, 2
    sw x24, 0(x23)
    li x25, 3
    sw x20, 0(x21)
    jal ra, emit_after_write
    fence iorw, iorw
    li x25, 4
    jal ra, wait_drain_ready_or_fail
    li x25, 5
    fence iorw, iorw
    mv x8, x24
    lw x9, 0(x19)
    bne x8, x9, case_compare_fail
    jal ra, emit_case_ok
    lw ra, 0(sp)
    addi sp, sp, 4
    jalr x0, 0(ra)

run_case4:
    addi sp, sp, -4
    sw ra, 0(sp)
    li x26, 4
    li x5, 0x64
    sb x5, 0(x28)
    li x23, DDR3_ADDR0
    li x24, 0x91E3554A
    li x21, DDR3_ADDR1
    li x20, 0x2FB86CD1
    li x19, DDR3_ADDR1
    jal ra, emit_case_start
    jal ra, wait_uart_tx_idle
    li x25, 2
    sw x24, 0(x23)
    .rept 100
    nop
    .endr
    li x25, 3
    sw x20, 0(x21)
    jal ra, emit_after_write
    fence iorw, iorw
    li x25, 4
    jal ra, wait_drain_ready_or_fail
    li x25, 5
    fence iorw, iorw
    li x19, DDR3_ADDR0
    mv x8, x24
    lw x9, 0(x19)
    bne x8, x9, case_compare_fail
    jal ra, emit_case_ok
    lw ra, 0(sp)
    addi sp, sp, 4
    jalr x0, 0(ra)

run_case5:
    addi sp, sp, -4
    sw ra, 0(sp)
    li x26, 5
    li x5, 0x65
    sb x5, 0(x28)
    li x23, DDR3_ADDR0
    li x24, 0x91E3554A
    li x21, DDR3_ADDR1
    li x20, 0x2FB86CD1
    li x19, DDR3_ADDR0
    jal ra, emit_case_start
    jal ra, wait_uart_tx_idle
    li x25, 2
    sw x24, 0(x23)
    li x25, 3
    fence iorw, iorw
    mv x8, x24
    lw x9, 0(x19)
    bne x8, x9, case_compare_fail
    sw x20, 0(x21)
    jal ra, emit_after_write
    fence iorw, iorw
    li x25, 4
    jal ra, wait_drain_ready_or_fail
    li x25, 5
    fence iorw, iorw
    mv x8, x24
    lw x9, 0(x19)
    bne x8, x9, case_compare_fail
    jal ra, emit_case_ok
    lw ra, 0(sp)
    addi sp, sp, 4
    jalr x0, 0(ra)

case_compare_fail:
    j emit_bad_and_halt

wait_drain_ready_or_fail:
    li x6, DRAIN_STATUS_TIMEOUT
wait_drain_ready_loop:
    lw x22, 0(x27)
    andi x5, x22, DDR3_STATUS_DRAIN_READY
    li x7, DDR3_STATUS_DRAIN_READY
    beq x5, x7, wait_drain_ready_done
    addi x6, x6, -1
    bne x6, x0, wait_drain_ready_loop
    li x8, 0
    li x9, 0
    j emit_bad_and_halt
wait_drain_ready_done:
    jalr x0, 0(ra)

wait_uart_tx_idle:
    lw x5, 0(x30)
    andi x5, x5, UART_STATUS_TX_BUSY_MASK
    bne x5, x0, wait_uart_tx_idle
    jalr x0, 0(ra)

emit_case_start:
    addi sp, sp, -4
    sw ra, 0(sp)
    la x10, msg_start
    jal ra, send_string
    mv x10, x26
    jal ra, send_digit
    jal ra, send_crlf
    lw ra, 0(sp)
    addi sp, sp, 4
    jalr x0, 0(ra)

emit_after_write:
    addi sp, sp, -4
    sw ra, 0(sp)
    la x10, msg_after_write
    jal ra, send_string
    mv x10, x26
    jal ra, send_digit
    jal ra, send_crlf
    lw ra, 0(sp)
    addi sp, sp, 4
    jalr x0, 0(ra)

emit_case_ok:
    addi sp, sp, -4
    sw ra, 0(sp)
    la x10, msg_ok
    jal ra, send_string
    mv x10, x26
    jal ra, send_digit
    jal ra, send_crlf
    lw ra, 0(sp)
    addi sp, sp, 4
    jalr x0, 0(ra)

emit_bad_and_halt:
    lw x22, 0(x27)
    la x10, msg_bad
    jal ra, send_string
    mv x10, x26
    jal ra, send_digit
    la x10, msg_phase_sep
    jal ra, send_string
    mv x10, x25
    jal ra, send_digit
    la x10, msg_addr
    jal ra, send_string
    mv x10, x19
    jal ra, print_hex32
    la x10, msg_expected
    jal ra, send_string
    mv x10, x8
    jal ra, print_hex32
    la x10, msg_actual
    jal ra, send_string
    mv x10, x9
    jal ra, print_hex32
    la x10, msg_w0_addr
    jal ra, send_string
    mv x10, x23
    jal ra, print_hex32
    la x10, msg_w0_data
    jal ra, send_string
    mv x10, x24
    jal ra, print_hex32
    la x10, msg_w1_addr
    jal ra, send_string
    mv x10, x21
    jal ra, print_hex32
    la x10, msg_w1_data
    jal ra, send_string
    mv x10, x20
    jal ra, print_hex32
    la x10, msg_drain_ready
    jal ra, send_string
    andi x5, x22, DDR3_STATUS_DRAIN_READY
    li x10, 0
    li x11, DDR3_STATUS_DRAIN_READY
    bne x5, x11, emit_bad_dr_done
    li x10, 1
emit_bad_dr_done:
    jal ra, send_digit
    la x10, msg_bridge_idle
    jal ra, send_string
    srli x10, x22, 2
    andi x10, x10, 1
    jal ra, send_digit
    la x10, msg_store_empty
    jal ra, send_string
    srli x10, x22, 1
    andi x10, x10, 1
    jal ra, send_digit
    la x10, msg_count0
    jal ra, send_string
    srli x10, x22, 8
    andi x10, x10, 0x7
    jal ra, send_digit
    la x10, msg_count1
    jal ra, send_string
    srli x10, x22, 11
    andi x10, x10, 0x7
    jal ra, send_digit
    la x10, msg_status
    jal ra, send_string
    mv x10, x22
    jal ra, print_hex32
    jal ra, send_crlf
    li x5, 0xE0
    add x5, x5, x26
    sb x5, 0(x28)
emit_bad_spin:
    j emit_bad_spin

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
    lw x5, 0(x30)
    andi x5, x5, UART_STATUS_TX_BUSY_MASK
    bne x5, x0, send_char_wait
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
    li x5, 0xEF
    sb x5, 0(x28)
    la x10, msg_trap
    jal ra, send_string
trap_unexpected_spin:
    j trap_unexpected_spin

.section .rodata
msg_boot:
    .asciz "S2 BOOT\r\n"
msg_ready:
    .asciz "S2 READY\r\n"
msg_start:
    .asciz "S2 START C="
msg_after_write:
    .asciz "S2 AFTER WRITE C="
msg_phase_sep:
    .asciz " P="
msg_ok:
    .asciz "S2 OK C="
msg_bad:
    .asciz "S2 BAD C="
msg_addr:
    .asciz " A="
msg_expected:
    .asciz " E="
msg_actual:
    .asciz " R="
msg_w0_addr:
    .asciz " W0_A="
msg_w0_data:
    .asciz " W0_D="
msg_w1_addr:
    .asciz " W1_A="
msg_w1_data:
    .asciz " W1_D="
msg_drain_ready:
    .asciz " DR="
msg_bridge_idle:
    .asciz " ID="
msg_store_empty:
    .asciz " SBE="
msg_count0:
    .asciz " C0="
msg_count1:
    .asciz " C1="
msg_status:
    .asciz " ST="
msg_all_ok:
    .asciz "S2 ALL OK\r\n"
msg_cal_fail:
    .asciz "S2 CAL FAIL ST="
msg_trap:
    .asciz "S2 TRAP\r\n"

.section .text
.balign 4
.org 0x800
thread1_spin:
    .rept 448
    nop
    .endr
    j thread1_spin
