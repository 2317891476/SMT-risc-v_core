.include "p2_mmio.inc"

.equ THREAD1_START_DELAY_CYCLES, 262144
.equ CALIB_TIMEOUT_CYCLES, 12500000
.equ SHARED_FLAG_ADDR, 0x00001000

.section .text
.globl _start

.macro UART_SEND_IMM_R ch, byte_reg, status_reg
    li \byte_reg, \ch
    # Give the store-data producer time to retire before the following SB.
    addi x0, x0, 0
    addi x0, x0, 0
    addi x0, x0, 0
    addi x0, x0, 0
    addi x0, x0, 0
    addi x0, x0, 0
.Luart_wait_\@:
    lw \status_reg, 0(x2)
    andi \status_reg, \status_reg, 1
    bne \status_reg, x0, .Luart_wait_\@
    sb \byte_reg, 0(x1)
.endm

.macro UART_SEND_REG byte_reg, status_reg
.Luart_reg_wait_\@:
    lw \status_reg, 0(x2)
    andi \status_reg, \status_reg, 1
    bne \status_reg, x0, .Luart_reg_wait_\@
    sb \byte_reg, 0(x1)
.endm

# Thread 0 (PC = 0x0000): validates DDR3 once, publishes CAL/DDR3 PASS,
# then releases thread 1 so both threads stream UART DIAG PASS forever.
_start:
    li x1, UART_TXDATA_ADDR
    li x2, UART_STATUS_ADDR
    li x3, TUBE_ADDR
    li x4, SHARED_FLAG_ADDR
    li x21, 0x04
    li x20, 0x11
    sw x0, 0(x4)
    sb x20, 0(x3)

    UART_SEND_IMM_R 0x53, x11, x12      # S
    UART_SEND_IMM_R 0x0D, x11, x12
    UART_SEND_IMM_R 0x0A, x11, x12

t0_run_ddr3_check:
    j ddr3_check_banner
t0_after_ddr3_pass:
    li x5, 1
    li x4, SHARED_FLAG_ADDR
    sw x5, 0(x4)
    li x21, 0x04
    sb x21, 0(x3)
    li x5, 0x55           # U
    li x6, 0x41           # A
    li x7, 0x52           # R
    li x8, 0x54           # T
    li x9, 0x20           # space
    li x10, 0x44          # D
    li x13, 0x49          # I
    li x14, 0x47          # G
    li x15, 0x50          # P
    li x18, 0x53          # S
    li x19, 0x0D
    li x20, 0x0A

t0_diag_loop:
    UART_SEND_REG x5, x12       # U
    UART_SEND_REG x6, x12       # A
    UART_SEND_REG x7, x12       # R
    UART_SEND_REG x8, x12       # T
    UART_SEND_REG x9, x12       # space
    UART_SEND_REG x10, x12      # D
    UART_SEND_REG x13, x12      # I
    UART_SEND_REG x6, x12       # A
    UART_SEND_REG x14, x12      # G
    UART_SEND_REG x9, x12       # space
    UART_SEND_REG x15, x12      # P
    UART_SEND_REG x6, x12       # A
    UART_SEND_REG x18, x12      # S
    UART_SEND_REG x18, x12      # S
    UART_SEND_REG x19, x12
    UART_SEND_REG x20, x12
    j t0_diag_loop

# Thread 1 (PC = 0x0800): waits until thread 0 sets a shared RAM release flag,
# then continuously streams UART DIAG PASS.
.org 0x800
_thread1_start:
    li x1, UART_TXDATA_ADDR
    li x2, UART_STATUS_ADDR
    li x4, SHARED_FLAG_ADDR
    li x24, THREAD1_START_DELAY_CYCLES

t1_start_delay:
    addi x24, x24, -1
    bne x24, x0, t1_start_delay

t1_wait_flag:
t1_wait_release:
    lw x23, 0(x4)
    beq x23, x0, t1_wait_release
    li x5, 0x55           # U
    li x6, 0x41           # A
    li x7, 0x52           # R
    li x8, 0x54           # T
    li x9, 0x20           # space
    li x10, 0x44          # D
    li x13, 0x49          # I
    li x14, 0x47          # G
    li x15, 0x50          # P
    li x18, 0x53          # S
    li x19, 0x0D
    li x20, 0x0A

t1_diag_loop:
    UART_SEND_REG x5, x17       # U
    UART_SEND_REG x6, x17       # A
    UART_SEND_REG x7, x17       # R
    UART_SEND_REG x8, x17       # T
    UART_SEND_REG x9, x17       # space
    UART_SEND_REG x10, x17      # D
    UART_SEND_REG x13, x17      # I
    UART_SEND_REG x6, x17       # A
    UART_SEND_REG x14, x17      # G
    UART_SEND_REG x9, x17       # space
    UART_SEND_REG x15, x17      # P
    UART_SEND_REG x6, x17       # A
    UART_SEND_REG x18, x17      # S
    UART_SEND_REG x18, x17      # S
    UART_SEND_REG x19, x17
    UART_SEND_REG x20, x17
    j t1_diag_loop

# ---------------------------------------------------------------------------
# ddr3_check_banner:
#   1. Poll DDR3 calibration complete
#   2. Print "CAL=1\r\n"
#   3. Write/read 0xDEADBEEF at DDR3_BASE
#   4. If compare passes, print "DDR3 PASS\r\n"
# ---------------------------------------------------------------------------
ddr3_check_banner:
    li x26, DDR3_STATUS_ADDR
    li x25, CALIB_TIMEOUT_CYCLES
ddr3_poll_calib:
    lw x5, 0(x26)
    andi x5, x5, 1
    bne x5, x0, ddr3_calib_done
    addi x25, x25, -1
    bne x25, x0, ddr3_poll_calib

    UART_SEND_IMM_R 0x43, x11, x12      # C
    UART_SEND_IMM_R 0x41, x11, x12      # A
    UART_SEND_IMM_R 0x4C, x11, x12      # L
    UART_SEND_IMM_R 0x3D, x11, x12      # =
    UART_SEND_IMM_R 0x30, x11, x12      # 0
    UART_SEND_IMM_R 0x0D, x11, x12
    UART_SEND_IMM_R 0x0A, x11, x12
    li x26, 0xFE
    sb x26, 0(x3)
ddr3_calib_fail_spin:
    j ddr3_calib_fail_spin

ddr3_calib_done:
    li x20, 0x12
    sb x20, 0(x3)
    UART_SEND_IMM_R 0x43, x11, x12      # C
    UART_SEND_IMM_R 0x41, x11, x12      # A
    UART_SEND_IMM_R 0x4C, x11, x12      # L
    UART_SEND_IMM_R 0x3D, x11, x12      # =
    UART_SEND_IMM_R 0x31, x11, x12      # 1
    UART_SEND_IMM_R 0x0D, x11, x12
    UART_SEND_IMM_R 0x0A, x11, x12

    li x6, DDR3_BASE
    lui x7, 0xDEADC
    addi x7, x7, -0x111     # 0xDEADBEEF
    sw x7, 0(x6)
    li x20, 0x13
    sb x20, 0(x3)
    lw x8, 0(x6)
    li x20, 0x14
    sb x20, 0(x3)

    bne x8, x7, ddr3_fail

    li x20, 0x15
    sb x20, 0(x3)
    UART_SEND_IMM_R 0x44, x11, x12      # D
    UART_SEND_IMM_R 0x44, x11, x12      # D
    UART_SEND_IMM_R 0x52, x11, x12      # R
    UART_SEND_IMM_R 0x33, x11, x12      # 3
    UART_SEND_IMM_R 0x20, x11, x12      # space
    UART_SEND_IMM_R 0x50, x11, x12      # P
    UART_SEND_IMM_R 0x41, x11, x12      # A
    UART_SEND_IMM_R 0x53, x11, x12      # S
    UART_SEND_IMM_R 0x53, x11, x12      # S
    UART_SEND_IMM_R 0x0D, x11, x12
    UART_SEND_IMM_R 0x0A, x11, x12
    j t0_after_ddr3_pass

ddr3_fail:
    UART_SEND_IMM_R 0x44, x11, x12      # D
    UART_SEND_IMM_R 0x44, x11, x12      # D
    UART_SEND_IMM_R 0x52, x11, x12      # R
    UART_SEND_IMM_R 0x33, x11, x12      # 3
    UART_SEND_IMM_R 0x20, x11, x12      # space
    UART_SEND_IMM_R 0x46, x11, x12      # F
    UART_SEND_IMM_R 0x41, x11, x12      # A
    UART_SEND_IMM_R 0x49, x11, x12      # I
    UART_SEND_IMM_R 0x4C, x11, x12      # L
    UART_SEND_IMM_R 0x0D, x11, x12
    UART_SEND_IMM_R 0x0A, x11, x12
    li x26, 0xFF
    sb x26, 0(x3)
ddr3_fail_spin:
    j ddr3_fail_spin

send_diag_line:
    mv x24, x15
    li x11, 0x55            # U
    jal x15, send_char
    li x11, 0x41            # A
    jal x15, send_char
    li x11, 0x52            # R
    jal x15, send_char
    li x11, 0x54            # T
    jal x15, send_char
    li x11, 0x20            # space
    jal x15, send_char
    li x11, 0x44            # D
    jal x15, send_char
    li x11, 0x49            # I
    jal x15, send_char
    li x11, 0x41            # A
    jal x15, send_char
    li x11, 0x47            # G
    jal x15, send_char
    li x11, 0x20            # space
    jal x15, send_char
    li x11, 0x50            # P
    jal x15, send_char
    li x11, 0x41            # A
    jal x15, send_char
    li x11, 0x53            # S
    jal x15, send_char
    li x11, 0x53            # S
    jal x15, send_char
    li x11, 0x0D
    jal x15, send_char
    li x11, 0x0A
    jal x15, send_char
    mv x15, x24
    jalr x0, 0(x15)

send_char:
    # Avoid the current store-data source hazard when callers load x11
    # immediately before entering this routine.
    addi x0, x0, 0
    addi x0, x0, 0
    addi x0, x0, 0
    addi x0, x0, 0
    addi x0, x0, 0
    addi x0, x0, 0
send_char_poll:
    lw x12, 0(x2)
    andi x12, x12, 1
    bne x12, x0, send_char_poll
    sb x11, 0(x1)
    jalr x0, 0(x15)
