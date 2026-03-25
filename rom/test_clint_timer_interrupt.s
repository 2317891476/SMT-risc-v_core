.section .text
.globl _start

# Test: CLINT Timer Interrupt Test
# Verifies:
# - CLINT timer interrupt setup and delivery
# - mtime/mtimecmp register access
# - mcause = 0x80000007 for timer interrupt
# - RV32 split-write safe sequence for mtimecmp

_start:
    # Initialize flag
    li x31, 0           # Interrupt handler flag
    
    # Test 1: Set up trap handler
    la x1, trap_handler
    csrw mtvec, x1
    
    # Test 2: Enable timer interrupt in mie
    li x2, 0x80         # MTIE bit
    csrrs x0, mie, x2
    csrr x3, mie
    andi x4, x3, 0x80
    beq x4, x0, test_fail
    
    # Test 3: Read current mtime
    li x5, 0x0200BFF8   # mtime lo address
    lw x6, 0(x5)        # Read mtime lo
    
    # Test 4: Set mtimecmp using RV32 split-write safe sequence
    # Write high word first with max value
    li x7, 0x02004004   # mtimecmp hi address
    li x8, 0xFFFFFFFF
    sw x8, 0(x7)        # mtimecmp hi = 0xFFFFFFFF
    
    # Write low word
    li x9, 0x02004000   # mtimecmp lo address
    addi x10, x6, 50    # mtime + 50
    sw x10, 0(x9)       # mtimecmp lo = mtime + 50
    
    # Write high word again with final value (0)
    sw x0, 0(x7)        # mtimecmp hi = 0
    
    # Test 5: Enable global interrupts
    li x11, 0x8         # MIE bit
    csrrs x0, mstatus, x11
    
    # Wait for timer interrupt
    li x12, 100
wait_loop:
    addi x12, x12, -1
    bnez x12, wait_loop
    
    # Test 6: Check if interrupt handler was called
    li x13, 1
    bne x31, x13, test_fail
    
    # Test 7: Verify mcause was saved correctly (0x80000007)
    # This would need to be checked in the handler
    
    # All tests passed
    li x14, 0x04
    li x15, 0x13000000  # TUBE address
    sw x14, 0(x15)      # Write PASS marker

test_pass:
    j test_pass

test_fail:
    li x14, 0xFF        # FAIL marker
    li x15, 0x13000000
    sw x14, 0(x15)
fail_loop:
    j fail_loop

# Trap handler
trap_handler:
    # Save mcause
    csrr x30, mcause
    
    # Check if it's a timer interrupt (mcause = 0x80000007)
    li x29, 0x80000007
    bne x30, x29, not_timer
    
    # Set flag to indicate timer interrupt was handled
    li x31, 1
    
    # Clear timer interrupt by setting mtimecmp to max
    li x28, 0x02004004  # mtimecmp hi
    li x27, 0xFFFFFFFF
    sw x27, 0(x28)
    li x28, 0x02004000  # mtimecmp lo
    sw x27, 0(x28)
    
not_timer:
    # Return from trap
    mret