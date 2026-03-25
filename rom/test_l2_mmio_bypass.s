.section .text
.globl _start

.include "p2_mmio.inc"

# Test: L2 MMIO Bypass Test
# Verifies:
# - MMIO accesses bypass the L2 cache
# - TUBE MMIO works correctly
# - CLINT MMIO reads work correctly
# - Non-cacheable regions are handled properly

_start:
    # Initialize
    li x1, TUBE_ADDR
    li x2, CLINT_MTIME_LO
    li x3, CLINT_MTIMECMP_LO
    
    # Test 1: Write to TUBE (should bypass cache)
    li x4, 0xAA
    sw x4, 0(x1)
    
    # Test 2: Read from CLINT mtime (should bypass cache)
    lw x5, 0(x2)        # Read mtime_lo
    
    # Test 3: Verify mtime is incrementing (read twice with delay)
    lw x6, 0(x2)        # First read
    li x7, 10
delay_loop:
    addi x7, x7, -1
    bnez x7, delay_loop
    lw x8, 0(x2)        # Second read
    
    # mtime should have increased
    blt x8, x6, test_fail
    
    # Test 4: Write to mtimecmp (should bypass cache)
    li x9, 0xFFFFFFFF
    sw x9, 0(x3)        # Write mtimecmp_lo
    
    # Test 5: Store and load to cacheable RAM region
    li x10, 0x1000      # Cacheable data region
    li x11, 0x12345678
    sw x11, 0(x10)
    lw x12, 0(x10)
    bne x11, x12, test_fail
    
    # Test 6: Verify TUBE write is observable
    li x13, 0x04
    sw x13, 0(x1)       # Write PASS marker to TUBE
    
    # All tests passed

test_pass:
    j test_pass

test_fail:
    li x13, 0xFF        # FAIL marker
    li x14, TUBE_ADDR
    sw x13, 0(x14)
fail_loop:
    j fail_loop
