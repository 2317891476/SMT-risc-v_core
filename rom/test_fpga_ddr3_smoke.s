# test_fpga_ddr3_smoke.s
# DDR3 read/write smoke test for FPGA.
#
# Test plan:
#   1. Write a walking-ones pattern (0x01, 0x02, … 0x80) to 8 consecutive
#      DDR3 words starting at 0x80000000.
#   2. Read them back and verify each word matches.
#   3. If all pass → UART prints "DDR3 PASS\r\n", TUBE ← 0x04.
#   4. On first mismatch → UART prints "DDR3 FAIL xx\r\n" (xx = failing
#      word index), TUBE ← 0xFF, then spin forever.
#
# Requires: ENABLE_DDR3=1, MIG calibration complete before first access.

.include "p2_mmio.inc"

.equ DDR3_BASE,  0x80000000
.equ TEST_WORDS, 8

.section .text
.globl _start

_start:
    # ── Register allocation ──
    # x1 = UART_TXDATA_ADDR
    # x2 = UART_STATUS_ADDR
    # x3 = TUBE_ADDR
    # x5 = DDR3_BASE pointer
    # x6 = loop counter
    # x7 = data pattern (walking 1)
    # x8 = readback value
    # x9 = scratch / comparison
    # x11 = character to send
    # x15 = link register for send_char

    li x1, UART_TXDATA_ADDR
    li x2, UART_STATUS_ADDR
    li x3, TUBE_ADDR

    # ──────────────────────────────────────────────────────
    # Phase 1: Write walking-ones pattern to DDR3
    # ──────────────────────────────────────────────────────
    li x5, DDR3_BASE
    li x6, 0               # counter = 0
    li x7, 1               # pattern = 0x00000001
write_loop:
    sw x7, 0(x5)           # DDR3[ptr] = pattern
    addi x5, x5, 4         # ptr += 4
    slli x7, x7, 1         # pattern <<= 1
    addi x6, x6, 1
    li x9, TEST_WORDS
    blt x6, x9, write_loop

    # ──────────────────────────────────────────────────────
    # Phase 2: Read back and verify
    # ──────────────────────────────────────────────────────
    li x5, DDR3_BASE
    li x6, 0
    li x7, 1
read_loop:
    lw x8, 0(x5)           # readback = DDR3[ptr]
    bne x8, x7, fail       # if readback != expected → fail
    addi x5, x5, 4
    slli x7, x7, 1
    addi x6, x6, 1
    li x9, TEST_WORDS
    blt x6, x9, read_loop

    # ──────────────────────────────────────────────────────
    # Phase 3: All words verified → PASS
    # ──────────────────────────────────────────────────────
    li x11, 0x44            # 'D'
    jal x15, send_char
    li x11, 0x44            # 'D'
    jal x15, send_char
    li x11, 0x52            # 'R'
    jal x15, send_char
    li x11, 0x33            # '3'
    jal x15, send_char
    li x11, 0x20            # ' '
    jal x15, send_char
    li x11, 0x50            # 'P'
    jal x15, send_char
    li x11, 0x41            # 'A'
    jal x15, send_char
    li x11, 0x53            # 'S'
    jal x15, send_char
    li x11, 0x53            # 'S'
    jal x15, send_char
    li x11, 0x0D            # CR
    jal x15, send_char
    li x11, 0x0A            # LF
    jal x15, send_char

    # Signal success to TUBE
    li x4, 0x04
    sb x4, 0(x3)

pass_spin:
    # Re-print message with delay
    li x14, 1000000
pass_delay:
    addi x14, x14, -1
    bne x14, x0, pass_delay
    j _start                # Repeat entire test forever

    # ──────────────────────────────────────────────────────
    # FAIL path: print "DDR3 FAIL xx\r\n", TUBE ← 0xFF
    # ──────────────────────────────────────────────────────
fail:
    li x11, 0x44            # 'D'
    jal x15, send_char
    li x11, 0x44            # 'D'
    jal x15, send_char
    li x11, 0x52            # 'R'
    jal x15, send_char
    li x11, 0x33            # '3'
    jal x15, send_char
    li x11, 0x20            # ' '
    jal x15, send_char
    li x11, 0x46            # 'F'
    jal x15, send_char
    li x11, 0x41            # 'A'
    jal x15, send_char
    li x11, 0x49            # 'I'
    jal x15, send_char
    li x11, 0x4C            # 'L'
    jal x15, send_char
    li x11, 0x20            # ' '
    jal x15, send_char
    # Print failing word index as two hex digits
    # x6 = failing index (0-7)
    srli x9, x6, 4         # high nibble
    andi x9, x9, 0x0F
    addi x11, x9, 0x30
    li x9, 10
    blt x11, x9, fail_hi_ok
    addi x11, x11, 7       # adjust for A-F (unnecessary for 0-7 but safe)
fail_hi_ok:
    jal x15, send_char
    andi x9, x6, 0x0F      # low nibble
    addi x11, x9, 0x30
    li x9, 0x3A
    blt x11, x9, fail_lo_ok
    addi x11, x11, 7
fail_lo_ok:
    jal x15, send_char
    li x11, 0x0D            # CR
    jal x15, send_char
    li x11, 0x0A            # LF
    jal x15, send_char

    # Signal failure to TUBE
    li x4, 0xFF
    sb x4, 0(x3)

fail_spin:
    j fail_spin             # Halt

    # ──────────────────────────────────────────────────────
    # send_char: poll UART and transmit x11
    # ──────────────────────────────────────────────────────
send_char:
poll_uart:
    lw x12, 0(x2)          # Read UART_STATUS
    andi x12, x12, 1       # bit 0 = TX_BUSY
    bne x12, x0, poll_uart # wait while busy
    sb x11, 0(x1)          # write char to UART_TXDATA
    jalr x0, 0(x15)        # return
