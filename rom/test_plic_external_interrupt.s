.section .text
.globl _start

.include "p2_mmio.inc"

# Test: PLIC External Interrupt Test
# Verifies:
# - PLIC priority register configuration
# - PLIC enable/threshold settings
# - External interrupt delivery with mcause = 0x8000000B
# - Claim/complete mechanism
# Note: External interrupt source must be driven by testbench

_start:
    # Initialize flag
    li x31, 0           # Interrupt handler flag
    
    # Test 1: Set up trap handler
    la x1, trap_handler
    csrw mtvec, x1
    
    # Test 2: Configure PLIC priority for source 1
    li x2, PLIC_PRIORITY1
    li x3, 1            # Priority = 1 (lowest non-zero)
    sw x3, 0(x2)
    
    # Test 3: Enable source 1 in PLIC
    li x4, PLIC_ENABLE
    li x5, 2            # Enable bit 1 (source 1)
    sw x5, 0(x4)
    
    # Test 4: Set PLIC threshold
    li x6, PLIC_THRESHOLD
    li x7, 0            # Threshold = 0 (allow all)
    sw x7, 0(x6)
    
    # Test 5: Enable external interrupt in mie
    li x8, 0x800        # MEIE bit
    csrrs x0, mie, x8
    
    # Test 6: Enable global interrupts
    li x9, 0x8          # MIE bit
    csrrs x0, mstatus, x9
    
    # At this point, we would need the testbench to assert external interrupt
    # For this test, we assume the testbench will drive the interrupt
    # Wait for interrupt handler to be called
    li x10, 1000        # Timeout counter
wait_loop:
    # Check if handler was called
    li x11, 1
    beq x31, x11, handler_called
    
    addi x10, x10, -1
    bnez x10, wait_loop
    
    # Timeout - fail
    j test_fail

handler_called:
    # All tests passed
    li x12, 0x04
    li x13, TUBE_ADDR
    sw x12, 0(x13)      # Write PASS marker

test_pass:
    j test_pass

test_fail:
    li x12, 0xFF        # FAIL marker
    li x13, TUBE_ADDR
    sw x12, 0(x13)
fail_loop:
    j fail_loop

# Trap handler
trap_handler:
    # Save mcause
    csrr x30, mcause
    
    # Check if it's an external interrupt (mcause = 0x8000000B)
    li x29, 0x8000000B
    bne x30, x29, not_external
    
    # Claim the interrupt
    li x28, PLIC_CLAIM_COMPLETE
    lw x27, 0(x28)      # Read claim (should be 1 for source 1)
    
    # Verify source ID
    li x26, 1
    bne x27, x26, not_external
    
    # Set flag to indicate external interrupt was handled
    li x31, 1
    
    # Complete the interrupt
    sw x27, 0(x28)      # Write source ID to complete
    
not_external:
    # Return from trap
    mret
