# test_fpga_ddr3_diag.s
# DDR3 diagnostic test: prints detailed readback info.
# 1) Print "S" (start marker)
# 2) Poll/print DDR3 calibration status (CAL=0/1)
# 3) Write 0xDEADBEEF to DDR3 address 0x80000000
# 4) Read it back
# 5) Print "W=dddddddd R=dddddddd" (expected vs actual)
# 6) If match: walking-ones test, then "DDR3 PASS" or "FAIL"

.include "p2_mmio.inc"

.equ DDR3_BASE,  0x80000000

.section .text
.globl _start

_start:
    li x1, UART_TXDATA_ADDR
    li x2, UART_STATUS_ADDR
    li x3, TUBE_ADDR

    # ── Print "S" to confirm CPU is alive ──
    li x11, 0x53            # 'S'
    jal x15, send_char

    # ── Poll DDR3 calibration status ──
    # Read DDR3_STATUS_ADDR (0x13000020), bit[0] = init_calib_complete
    li x4, DDR3_STATUS_ADDR
    li x17, 0               # poll counter (for timeout print)
poll_calib:
    lw x18, 0(x4)           # x18 = DDR3 status
    andi x18, x18, 1        # bit 0 = init_calib_complete
    bne x18, x0, calib_done # if 1, calibration complete
    addi x17, x17, 1
    li x9, 5000000          # ~500ms at 10MHz (generous timeout)
    blt x17, x9, poll_calib

    # Timeout — calibration never completed
    # Print "CAL=0\r\n"
    li x11, 0x43            # 'C'
    jal x15, send_char
    li x11, 0x41            # 'A'
    jal x15, send_char
    li x11, 0x4C            # 'L'
    jal x15, send_char
    li x11, 0x3D            # '='
    jal x15, send_char
    li x11, 0x30            # '0'
    jal x15, send_char
    li x11, 0x0D
    jal x15, send_char
    li x11, 0x0A
    jal x15, send_char
    # Print poll count for reference
    li x11, 0x4E            # 'N'
    jal x15, send_char
    li x11, 0x3D            # '='
    jal x15, send_char
    mv x10, x17
    jal x15, print_hex32
    li x11, 0x0D
    jal x15, send_char
    li x11, 0x0A
    jal x15, send_char
    li x4, 0xFE
    sb x4, 0(x3)
calib_fail_halt:
    j calib_fail_halt

calib_done:
    # Print "CAL=1\r\n"
    li x11, 0x43            # 'C'
    jal x15, send_char
    li x11, 0x41            # 'A'
    jal x15, send_char
    li x11, 0x4C            # 'L'
    jal x15, send_char
    li x11, 0x3D            # '='
    jal x15, send_char
    li x11, 0x31            # '1'
    jal x15, send_char
    li x11, 0x0D
    jal x15, send_char
    li x11, 0x0A
    jal x15, send_char

    # ── Write 0xDEADBEEF to DDR3 ──
    li x5, DDR3_BASE
    li x7, 0xDEAD0000       # upper half (will need two instructions)
    # Build 0xDEADBEEF:  lui + addi
    lui x7, 0xDEADB         # x7 = 0xDEADB000
    addi x7, x7, -273       # 0xDEADB000 + 0xFFFFFEEF = 0xDEADAEEF? no...
    # Actually: 0xBEEF = 48879, but addi only does signed 12-bit
    # Use lui 0xDEADC, then addi -0x111 = -273 → 0xDEADC000 - 0x111 = 0xDEADBEEF
    lui x7, 0xDEADC         # x7 = 0xDEADC000
    addi x7, x7, -0x111     # x7 = 0xDEADC000 - 0x111 = 0xDEADBEEF

    sw x7, 0(x5)            # DDR3[0] = 0xDEADBEEF

    # ── Print "W=" ──
    li x11, 0x57            # 'W'
    jal x15, send_char
    li x11, 0x3D            # '='
    jal x15, send_char
    # Print x7 as 8 hex digits
    mv x10, x7
    jal x15, print_hex32

    li x11, 0x20            # ' '
    jal x15, send_char

    # ── Read back from DDR3 ──
    lw x8, 0(x5)            # x8 = DDR3[0] readback

    # ── Print "R=" ──
    li x11, 0x52            # 'R'
    jal x15, send_char
    li x11, 0x3D            # '='
    jal x15, send_char
    mv x10, x8
    jal x15, print_hex32

    li x11, 0x0D
    jal x15, send_char
    li x11, 0x0A
    jal x15, send_char

    # ── Check match ──
    bne x8, x7, fail

    # ── PASS: try walking-ones ──
    li x5, DDR3_BASE
    li x6, 0
    li x7, 1
write_loop:
    sw x7, 0(x5)
    addi x5, x5, 4
    slli x7, x7, 1
    addi x6, x6, 1
    li x9, 8
    blt x6, x9, write_loop

    li x5, DDR3_BASE
    li x6, 0
    li x7, 1
read_loop:
    lw x8, 0(x5)
    bne x8, x7, fail_walk
    addi x5, x5, 4
    slli x7, x7, 1
    addi x6, x6, 1
    li x9, 8
    blt x6, x9, read_loop

    # ── All PASS ──
    li x11, 0x44            # 'D'
    jal x15, send_char
    li x11, 0x44
    jal x15, send_char
    li x11, 0x52            # 'R'
    jal x15, send_char
    li x11, 0x33            # '3'
    jal x15, send_char
    li x11, 0x20
    jal x15, send_char
    li x11, 0x50            # 'P'
    jal x15, send_char
    li x11, 0x41            # 'A'
    jal x15, send_char
    li x11, 0x53            # 'S'
    jal x15, send_char
    li x11, 0x53
    jal x15, send_char
    li x11, 0x0D
    jal x15, send_char
    li x11, 0x0A
    jal x15, send_char
    li x4, 0x04
    sb x4, 0(x3)

pass_spin:
    li x14, 1000000
pass_delay:
    addi x14, x14, -1
    bne x14, x0, pass_delay
    j _start

fail:
    # Initial DEADBEEF test failed
    li x11, 0x46            # 'F'
    jal x15, send_char
    li x11, 0x41            # 'A'
    jal x15, send_char
    li x11, 0x49            # 'I'
    jal x15, send_char
    li x11, 0x4C            # 'L'
    jal x15, send_char
    li x11, 0x31            # '1'
    jal x15, send_char
    li x11, 0x0D
    jal x15, send_char
    li x11, 0x0A
    jal x15, send_char
    li x4, 0xFF
    sb x4, 0(x3)
fail_halt:
    j fail_halt

fail_walk:
    # Walking-ones failed at index x6
    li x11, 0x46            # 'F'
    jal x15, send_char
    li x11, 0x32            # '2'
    jal x15, send_char
    li x11, 0x5B            # '['
    jal x15, send_char
    # Print index
    addi x11, x6, 0x30
    jal x15, send_char
    li x11, 0x5D            # ']'
    jal x15, send_char
    # Print expected
    li x11, 0x20
    jal x15, send_char
    li x11, 0x45            # 'E'
    jal x15, send_char
    li x11, 0x3D            # '='
    jal x15, send_char
    mv x10, x7
    jal x15, print_hex32
    # Print actual
    li x11, 0x20
    jal x15, send_char
    li x11, 0x41            # 'A'
    jal x15, send_char
    li x11, 0x3D            # '='
    jal x15, send_char
    mv x10, x8
    jal x15, print_hex32
    li x11, 0x0D
    jal x15, send_char
    li x11, 0x0A
    jal x15, send_char
    li x4, 0xFF
    sb x4, 0(x3)
fail_walk_halt:
    j fail_walk_halt

# ──────────────────────────────────────────────────────
# send_char: transmit x11 via UART (poll TX_BUSY)
# ──────────────────────────────────────────────────────
send_char:
poll_uart:
    lw x12, 0(x2)
    andi x12, x12, 1
    bne x12, x0, poll_uart
    sb x11, 0(x1)
    jalr x0, 0(x15)

# ──────────────────────────────────────────────────────
# print_hex32: print x10 as 8 hex digits via UART
# Uses x10 (value), x11 (char), x13 (shift), x14 (nibble), x15 (link)
# Clobbers x10, x11, x13, x14, x16 (save link)
# ──────────────────────────────────────────────────────
print_hex32:
    mv x16, x15            # save return address
    li x13, 28             # start from bit 28 (high nibble)
hex_loop:
    srl x14, x10, x13     # shift right by x13
    andi x14, x14, 0x0F   # mask low nibble
    addi x11, x14, 0x30   # '0' + nibble
    li x9, 0x3A            # ':' = '0' + 10
    blt x11, x9, hex_ok
    addi x11, x11, 7      # adjust for A-F: 'A' - ':' = 7
hex_ok:
    jal x15, send_char
    addi x13, x13, -4
    bge x13, x0, hex_loop
    mv x15, x16            # restore return address
    jalr x0, 0(x15)
