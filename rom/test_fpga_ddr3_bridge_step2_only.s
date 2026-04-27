.include "p2_mmio.inc"

.equ BRIDGE_STACK_TOP,          0x00000FF0
.equ DDR3_BASE_ADDR,            0x80000000
.equ DDR3_ADDR0,                DDR3_BASE_ADDR
.equ DDR3_ADDR1,                DDR3_BASE_ADDR + 4
.equ CALIB_TIMEOUT_CYCLES,      25000000
.equ DRAIN_STATUS_TIMEOUT,      25000000
.equ DDR3_STATUS_CALIB_MASK,    0x01
.equ DDR3_STATUS_DRAIN_READY,   0x07

.equ EVT_READY,                 0x01
.equ EVT_C1_OK,                 0x11
.equ EVT_C2_OK,                 0x12
.equ EVT_C3_START,              0x31
.equ EVT_C3_AFTER,              0x32
.equ EVT_C3_OK,                 0x33
.equ EVT_C4_START,              0x41
.equ EVT_C4_AFTER,              0x42
.equ EVT_C4_OK,                 0x43
.equ EVT_C5_START,              0x51
.equ EVT_C5_AFTER,              0x52
.equ EVT_C5_OK,                 0x53
.equ EVT_BAD,                   0xE0
.equ EVT_CAL_FAIL,              0xE1
.equ EVT_TRAP,                  0xEF
.equ EVT_SUMMARY,               0xF0

.section .text
.globl _start

_start:
    csrr x6, mhartid
    bne x6, x0, thread1_spin

    li sp, BRIDGE_STACK_TOP
    li x31, DEBUG_BEACON_EVT_ADDR
    li x30, TUBE_ADDR
    li x29, DDR3_STATUS_ADDR
    li x27, 0

    la x5, trap_unexpected
    csrw mtvec, x5
    csrw mie, x0
    li x5, 0x08
    csrrc x0, mstatus, x5

    li x5, 0x31
    sb x5, 0(x30)

    li x6, CALIB_TIMEOUT_CYCLES
poll_calib:
    lw x22, 0(x29)
    andi x5, x22, DDR3_STATUS_CALIB_MASK
    bne x5, x0, calib_done
    addi x6, x6, -1
    bne x6, x0, poll_calib

    ori x27, x27, 0x80
    li x10, EVT_CAL_FAIL
    li x11, 0
    jal ra, emit_event
    jal ra, emit_summary
    li x5, 0xE0
    sb x5, 0(x30)
calib_fail_spin:
    j calib_fail_spin

calib_done:
    li x10, EVT_READY
    li x11, 0
    jal ra, emit_event

    jal ra, run_case1
    jal ra, run_case2
    jal ra, run_case3
    jal ra, run_case4
    jal ra, run_case5

    jal ra, emit_summary
    li x5, 0x04
    sb x5, 0(x30)
all_ok_spin:
    j all_ok_spin

run_case1:
    addi sp, sp, -4
    sw ra, 0(sp)
    li x26, 1
    li x5, 0x61
    sb x5, 0(x30)
    li x23, DDR3_ADDR0
    li x24, 0x13A5C7EF
    li x21, 0
    li x20, 0
    li x19, DDR3_ADDR0
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
    jal ra, mark_case_pass
    li x10, EVT_C1_OK
    li x11, 0
    jal ra, emit_event
    lw ra, 0(sp)
    addi sp, sp, 4
    jalr x0, 0(ra)

run_case2:
    addi sp, sp, -4
    sw ra, 0(sp)
    li x26, 2
    li x5, 0x62
    sb x5, 0(x30)
    li x23, DDR3_ADDR1
    li x24, 0xE14C82B7
    li x21, 0
    li x20, 0
    li x19, DDR3_ADDR1
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
    jal ra, mark_case_pass
    li x10, EVT_C2_OK
    li x11, 0
    jal ra, emit_event
    lw ra, 0(sp)
    addi sp, sp, 4
    jalr x0, 0(ra)

run_case3:
    addi sp, sp, -4
    sw ra, 0(sp)
    li x26, 3
    li x5, 0x63
    sb x5, 0(x30)
    li x23, DDR3_ADDR0
    li x24, 0x5AC3F10E
    li x21, DDR3_ADDR1
    li x20, 0xC67D29B4
    li x19, DDR3_ADDR0
    li x10, EVT_C3_START
    li x11, 0
    jal ra, emit_event
    li x25, 2
    sw x24, 0(x23)
    li x25, 3
    sw x20, 0(x21)
    li x10, EVT_C3_AFTER
    li x11, 0
    jal ra, emit_event
    fence iorw, iorw
    li x25, 4
    jal ra, wait_drain_ready_or_fail
    li x25, 5
    fence iorw, iorw
    mv x8, x24
    lw x9, 0(x19)
    bne x8, x9, case_compare_fail
    jal ra, mark_case_pass
    li x10, EVT_C3_OK
    li x11, 0
    jal ra, emit_event
    lw ra, 0(sp)
    addi sp, sp, 4
    jalr x0, 0(ra)

run_case4:
    addi sp, sp, -4
    sw ra, 0(sp)
    li x26, 4
    li x5, 0x64
    sb x5, 0(x30)
    li x23, DDR3_ADDR0
    li x24, 0x91E3554A
    li x21, DDR3_ADDR1
    li x20, 0x2FB86CD1
    li x19, DDR3_ADDR0
    li x10, EVT_C4_START
    li x11, 0
    jal ra, emit_event
    li x25, 2
    sw x24, 0(x23)
    .rept 100
    nop
    .endr
    li x25, 3
    sw x20, 0(x21)
    li x10, EVT_C4_AFTER
    li x11, 0
    jal ra, emit_event
    fence iorw, iorw
    li x25, 4
    jal ra, wait_drain_ready_or_fail
    li x25, 5
    fence iorw, iorw
    mv x8, x24
    lw x9, 0(x19)
    bne x8, x9, case_compare_fail
    jal ra, mark_case_pass
    li x10, EVT_C4_OK
    li x11, 0
    jal ra, emit_event
    lw ra, 0(sp)
    addi sp, sp, 4
    jalr x0, 0(ra)

run_case5:
    addi sp, sp, -4
    sw ra, 0(sp)
    li x26, 5
    li x5, 0x65
    sb x5, 0(x30)
    li x23, DDR3_ADDR0
    li x24, 0x91E3554A
    li x21, DDR3_ADDR1
    li x20, 0x2FB86CD1
    li x19, DDR3_ADDR0
    li x10, EVT_C5_START
    li x11, 0
    jal ra, emit_event
    li x25, 2
    sw x24, 0(x23)
    li x25, 3
    fence iorw, iorw
    mv x8, x24
    lw x9, 0(x19)
    bne x8, x9, case_compare_fail
    sw x20, 0(x21)
    li x10, EVT_C5_AFTER
    li x11, 0
    jal ra, emit_event
    fence iorw, iorw
    li x25, 4
    jal ra, wait_drain_ready_or_fail
    li x25, 5
    fence iorw, iorw
    mv x8, x24
    lw x9, 0(x19)
    bne x8, x9, case_compare_fail
    jal ra, mark_case_pass
    li x10, EVT_C5_OK
    li x11, 0
    jal ra, emit_event
    lw ra, 0(sp)
    addi sp, sp, 4
    jalr x0, 0(ra)

case_compare_fail:
    j emit_bad_and_halt

wait_drain_ready_or_fail:
    li x6, DRAIN_STATUS_TIMEOUT
wait_drain_ready_loop:
    lw x22, 0(x29)
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

mark_case_pass:
    addi x12, x26, -1
    li x13, 1
    sll x13, x13, x12
    or x27, x27, x13
    jalr x0, 0(ra)

emit_event:
    slli x12, x11, 8
    or x12, x12, x10
    sw x12, 0(x31)
    jalr x0, 0(ra)

emit_summary:
    mv x18, ra
    li x10, EVT_SUMMARY
    mv x11, x27
    jal ra, emit_event
    mv ra, x18
    jalr x0, 0(ra)

emit_bad_and_halt:
    ori x27, x27, 0x80
    andi x11, x25, 0x0F
    slli x11, x11, 4
    andi x12, x26, 0x0F
    or x11, x11, x12
    li x10, EVT_BAD
    jal ra, emit_event
    jal ra, emit_summary
    li x5, 0xE0
    add x5, x5, x26
    sb x5, 0(x30)
emit_bad_spin:
    j emit_bad_spin

trap_unexpected:
    ori x27, x27, 0x80
    li x10, EVT_TRAP
    li x11, 0
    jal ra, emit_event
    jal ra, emit_summary
    li x5, 0xEF
    sb x5, 0(x30)
trap_unexpected_spin:
    j trap_unexpected_spin

.section .text
.balign 4
.org 0x800
thread1_spin:
    .rept 448
    nop
    .endr
    j thread1_spin
