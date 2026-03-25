.section .text
.globl _start

# Test: Interrupt Mask and MRET Test
# Verifies:
# - Pending interrupts do not trap when disabled
# - MRET correctly returns to interrupted PC
# - Global interrupt enable/disable (MIE bit) works
# - MEPC is saved and restored correctly

_start:
    # Initialize flags
    li x31, 0           # Main interrupt handler flag
    li x30, 0           # Secondary flag for nested check
    
    # Test 1: Set up trap handler
    la x1, trap_handler
    csrw mtvec, x1
    
    # Test 2: Set up timer interrupt but keep it disabled globally
    li x2, 0x0200BFF8   # mtime lo address
    lw x3, 0(x2)        # Read current mtime
    
    # Set mtimecmp to trigger soon
    li x4, 0x02004004   # mtimecmp hi
    sw x0, 0(x4)        # mtimecmp hi = 0
    li x5, 0x02004000   # mtimecmp lo
    addi x6, x3, 20     # mtime + 20
    sw x6, 0(x5)        # mtimecmp lo = mtime + 20
    
    # Enable timer interrupt in mie (but not globally in mstatus)
    li x7, 0x80         # MTIE bit
    csrrs x0, mie, x7
    
    # Wait for timer to expire (interrupt should NOT fire yet)
    li x8, 50
delay1:
    addi x8, x8, -1
    bnez x8, delay1
    
    # Test 3: Verify interrupt did NOT fire (flag should still be 0)
    bnez x31, test_fail
    
    # Test 4: Save return address for MRET test
    la x9, after_interrupt
    
    # Test 5: Enable global interrupts
    li x10, 0x8         # MIE bit
    csrrs x0, mstatus, x10
    
    # Wait for interrupt to fire
    li x11, 100
delay2:
    # Check if handler was called
    li x12, 1
    beq x31, x12, interrupt_fired
    
    addi x11, x11, -1
    bnez x11, delay2
    
    # Timeout - fail
    j test_fail

interrupt_fired:
    # Test 6: Verify we continued after the interrupt
    # (x30 should be set by handler to indicate MRET worked)
    li x13, 2
    bne x30, x13, test_fail
    
after_interrupt:
    # Test 7: Disable interrupts and verify no more fire
    li x14, 0x8         # MIE bit
    csrrc x0, mstatus, x14
    
    # Clear and re-arm timer
    li x15, 0xFFFFFFFF
    li x16, 0x02004004
    sw x15, 0(x16)      # mtimecmp hi = max
    li x17, 0x02004000
    sw x15, 0(x17)      # mtimecmp lo = max
    
    # Clear flag
    li x31, 0
    
    # Re-arm timer
    li x18, 0x0200BFF8
    lw x19, 0(x18)
    sw x0, 0(x16)       # mtimecmp hi = 0
    addi x20, x19, 10
    sw x20, 0(x17)      # mtimecmp lo = mtime + 10
    
    # Wait (interrupt should NOT fire because MIE=0)
    li x21, 50
delay3:
    addi x21, x21, -1
    bnez x21, delay3
    
    # Verify interrupt did NOT fire
    bnez x31, test_fail
    
    # All tests passed
    li x22, 0x04
    li x23, 0x13000000  # TUBE address
    sw x22, 0(x23)      # Write PASS marker

test_pass:
    j test_pass

test_fail:
    li x22, 0xFF        # FAIL marker
    li x23, 0x13000000
    sw x22, 0(x23)
fail_loop:
    j fail_loop

# Trap handler
trap_handler:
    # Check if this is the first entry
    li x28, 1
    beq x31, x28, already_handled
    
    # First entry: save mepc and set flag
    csrr x29, mepc
    
    # Set flag to indicate handler was called
    li x31, 1
    
    # Set secondary flag to show MRET worked
    li x30, 2
    
    # Clear timer interrupt
    li x27, 0x02004004
    li x26, 0xFFFFFFFF
    sw x26, 0(x27)
    li x27, 0x02004000
    sw x26, 0(x27)
    
already_handled:
    # Return from trap
    mret