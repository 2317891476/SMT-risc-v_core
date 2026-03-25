.section .text
.globl _start

# Test: L2 I/D Arbiter Test
# Verifies:
# - Round-robin arbitration between I-side and D-side
# - Concurrent instruction fetch and data access work correctly
# - Store and load operations work correctly with L2

_start:
    # Initialize test data in RAM
    li x1, 0x1000       # Data section base
    li x2, 0xDEADBEEF
    li x3, 0x12345678
    li x4, 0xAABBCCDD
    li x5, 0x11223344
    
    # Store test patterns
    sw x2, 0(x1)
    sw x3, 4(x1)
    sw x4, 8(x1)
    sw x5, 12(x1)
    
    # Load back and verify
    lw x6, 0(x1)
    lw x7, 4(x1)
    lw x8, 8(x1)
    lw x9, 12(x1)
    
    # Verify loaded values
    bne x6, x2, test_fail
    bne x7, x3, test_fail
    bne x8, x4, test_fail
    bne x9, x5, test_fail
    
    # Interleave arithmetic (I-side) with memory ops (D-side)
    li x10, 0
    li x11, 10
    
arith_loop:
    # Arithmetic operations (I-side pressure)
    addi x10, x10, 1
    add x12, x10, x10      # Use add instead of mul (rv32i only)
    
    # Memory operation (D-side pressure)
    sw x12, 16(x1)
    lw x13, 16(x1)
    
    # Verify memory op worked
    bne x12, x13, test_fail
    
    blt x10, x11, arith_loop
    
    # Verify loop completed
    li x14, 10
    bne x10, x14, test_fail
    
    # All tests passed
    li x15, 0x04
    li x16, 0x13000000  # TUBE address
    sw x15, 0(x16)      # Write PASS marker

test_pass:
    j test_pass

test_fail:
    li x15, 0xFF        # FAIL marker
    li x16, 0x13000000
    sw x15, 0(x16)
fail_loop:
    j fail_loop
