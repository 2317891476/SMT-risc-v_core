.section .text
.globl _start

.include "p2_mmio.inc"

# Wrong-path MMIO loads must be killed before they reach M1 or update ARF.

_start:
    li x1, UART_RXDATA_ADDR
    li x5, 0x55

    beq x0, x0, target
    lw x5, 0(x1)

target:
    li x6, 0x55
    bne x5, x6, test_fail

    li x7, 0x04
    li x8, TUBE_ADDR
    sw x7, 0(x8)

test_pass:
    j test_pass

test_fail:
    li x7, 0xFF
    li x8, TUBE_ADDR
    sw x7, 0(x8)
fail_loop:
    j fail_loop
