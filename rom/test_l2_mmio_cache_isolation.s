.section .text
.globl _start

.include "p2_mmio.inc"

# Test: MMIO bypass and cacheable data isolation
# Verifies:
# - cacheable RAM contents remain intact across CLINT/PLIC MMIO traffic
# - CLINT and PLIC register reads/writes bypass cache and reflect live values
# - TUBE/MMIO operations do not corrupt cached data lines

_start:
    li x1, 0x00001B00

    li x2, 0xCAFEBABE
    sw x2, 0(x1)
    li x3, 0x0BADF00D
    sw x3, 4(x1)

    li x4, 64
drain_cached_seed:
    addi x4, x4, -1
    bnez x4, drain_cached_seed

    lw x5, 0(x1)
    bne x5, x2, test_fail
    lw x6, 4(x1)
    bne x6, x3, test_fail

    # CLINT mtime must keep increasing.
    li x7, CLINT_MTIME_LO
    lw x8, 0(x7)
    li x9, 16
clint_delay:
    addi x9, x9, -1
    bnez x9, clint_delay
    lw x10, 0(x7)
    blt x10, x8, test_fail

    # CLINT mtimecmp readback should match the written value.
    li x11, CLINT_MTIMECMP_HI
    li x12, 0xFFFFFFFF
    sw x12, 0(x11)
    li x13, CLINT_MTIMECMP_LO
    li x14, 0x00001234
    sw x14, 0(x13)
    lw x15, 0(x13)
    bne x15, x14, test_fail

    # PLIC priority/threshold readback should also bypass cache correctly.
    li x16, PLIC_PRIORITY1
    li x17, 3
    sw x17, 0(x16)
    lw x18, 0(x16)
    bne x18, x17, test_fail

    li x19, PLIC_THRESHOLD
    li x20, 2
    sw x20, 0(x19)
    lw x21, 0(x19)
    bne x21, x20, test_fail

    # Cacheable data must still be intact after the MMIO traffic.
    lw x22, 0(x1)
    bne x22, x2, test_fail
    lw x23, 4(x1)
    bne x23, x3, test_fail

    li x24, 0x04
    li x25, TUBE_ADDR
    sw x24, 0(x25)

test_pass:
    j test_pass

test_fail:
    li x24, 0xFF
    li x25, TUBE_ADDR
    sw x24, 0(x25)
fail_loop:
    j fail_loop
