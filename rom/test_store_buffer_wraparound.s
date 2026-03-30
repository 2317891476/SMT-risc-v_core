.section .text
.globl _start

.include "p2_mmio.inc"

# Test: Store Buffer wraparound / repeated overwrite
# Verifies:
# - more stores than SB depth complete correctly
# - head/tail pointer wraparound does not corrupt data
# - later overwrites become architecturally visible

_start:
    li x1, 0x00001500

    # Clear 8 words.
    sw x0, 0(x1)
    sw x0, 4(x1)
    sw x0, 8(x1)
    sw x0, 12(x1)
    sw x0, 16(x1)
    sw x0, 20(x1)
    sw x0, 24(x1)
    sw x0, 28(x1)

    # First wave: 8 consecutive stores.
    li x2, 0x11111111
    sw x2, 0(x1)
    li x2, 0x22222222
    sw x2, 4(x1)
    li x2, 0x33333333
    sw x2, 8(x1)
    li x2, 0x44444444
    sw x2, 12(x1)
    li x2, 0x55555555
    sw x2, 16(x1)
    li x2, 0x66666666
    sw x2, 20(x1)
    li x2, 0x77777777
    sw x2, 24(x1)
    li x2, 0x88888888
    sw x2, 28(x1)

    # Verify the first wave.
    lw x3, 0(x1)
    li x4, 0x11111111
    bne x3, x4, test_fail
    lw x3, 4(x1)
    li x4, 0x22222222
    bne x3, x4, test_fail
    lw x3, 8(x1)
    li x4, 0x33333333
    bne x3, x4, test_fail
    lw x3, 12(x1)
    li x4, 0x44444444
    bne x3, x4, test_fail
    lw x3, 16(x1)
    li x4, 0x55555555
    bne x3, x4, test_fail
    lw x3, 20(x1)
    li x4, 0x66666666
    bne x3, x4, test_fail
    lw x3, 24(x1)
    li x4, 0x77777777
    bne x3, x4, test_fail
    lw x3, 28(x1)
    li x4, 0x88888888
    bne x3, x4, test_fail

    # Second wave: overwrite the first four words.
    li x2, 0xA1A1A1A1
    sw x2, 0(x1)
    li x2, 0xB2B2B2B2
    sw x2, 4(x1)
    li x2, 0xC3C3C3C3
    sw x2, 8(x1)
    li x2, 0xD4D4D4D4
    sw x2, 12(x1)

    # Verify overwrites plus untouched tail words.
    lw x3, 0(x1)
    li x4, 0xA1A1A1A1
    bne x3, x4, test_fail
    lw x3, 4(x1)
    li x4, 0xB2B2B2B2
    bne x3, x4, test_fail
    lw x3, 8(x1)
    li x4, 0xC3C3C3C3
    bne x3, x4, test_fail
    lw x3, 12(x1)
    li x4, 0xD4D4D4D4
    bne x3, x4, test_fail
    lw x3, 16(x1)
    li x4, 0x55555555
    bne x3, x4, test_fail
    lw x3, 20(x1)
    li x4, 0x66666666
    bne x3, x4, test_fail
    lw x3, 24(x1)
    li x4, 0x77777777
    bne x3, x4, test_fail
    lw x3, 28(x1)
    li x4, 0x88888888
    bne x3, x4, test_fail

    li x5, 0x04
    li x6, TUBE_ADDR
    sw x5, 0(x6)

test_pass:
    j test_pass

test_fail:
    li x5, 0xFF
    li x6, TUBE_ADDR
    sw x5, 0(x6)
fail_loop:
    j fail_loop
