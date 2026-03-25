.section .text
.globl _start

# Test: L2 I-Cache Refill Test
# Verifies:
# - L2 cache handles instruction fetch refills correctly
# - Sequential instruction execution across cache line boundaries
# - Multiple cache lines are accessed correctly

_start:
    # Initialize registers
    li x1, 0
    li x2, 0
    li x3, 0
    
    # Execute a sequence of instructions that span multiple cache lines
    # Each cache line is 32 bytes = 8 instructions
    # We'll execute enough instructions to trigger multiple refills
    
    # First sequence: simple arithmetic (should trigger L2 access)
    li x1, 1
    li x2, 2
    li x3, 3
    li x4, 4
    li x5, 5
    li x6, 6
    li x7, 7
    li x8, 8
    
    # Verify values
    add x9, x1, x2      # x9 = 3
    add x10, x3, x4     # x10 = 7
    add x11, x5, x6     # x11 = 11
    add x12, x7, x8     # x12 = 15
    
    # More instructions to trigger additional cache line accesses
    add x13, x9, x10    # x13 = 10
    add x14, x11, x12   # x14 = 26
    
    # Verify results
    li x15, 10
    bne x13, x15, test_fail
    li x16, 26
    bne x14, x16, test_fail
    
    # Execute a loop to ensure instruction fetch works correctly
    li x17, 0
    li x18, 100
loop_start:
    addi x17, x17, 1
    blt x17, x18, loop_start
    
    # Verify loop executed correctly
    li x19, 100
    bne x17, x19, test_fail
    
    # All tests passed
    li x20, 0x04
    li x21, 0x13000000  # TUBE address
    sw x20, 0(x21)      # Write PASS marker

test_pass:
    j test_pass

test_fail:
    li x20, 0xFF        # FAIL marker
    li x21, 0x13000000
    sw x20, 0(x21)
fail_loop:
    j fail_loop