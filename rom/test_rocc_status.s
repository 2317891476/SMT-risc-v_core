.section .text
.globl _start

# Test: RoCC STATUS.READ Test (test_id=14)
# Verifies STATUS.READ command returns correct format
#
# Test sequence:
#   1. Read status when idle (should show not busy)
#   2. Start a DMA operation
#   3. Poll status until operation completes
#   4. Verify status format: {29'b0, error, done, busy}

_start:
    # Mark test as RoCC STATUS test (test_id=14 marker: addi x3, x0, 14)
    li x3, 14
    
    # Test 1: Read status when accelerator is idle
    # STATUS.READ (funct7=5)
    # Expected: busy=0, done=0, error=0 (upper 29 bits should be 0)
    .insn r 0x0B, 0, 5, x4, x0, x0
    
    # Verify format: upper 29 bits should be 0
    li x5, 0xFFFFFFF8      # Mask for upper 29 bits
    and x6, x4, x5
    bne x6, x0, test_fail   # Upper bits must be 0
    
    # Verify lower 3 bits are 0 (idle state)
    andi x6, x4, 0x7
    bne x6, x0, test_fail   # Should be 0 when idle
    
    # Test 2: Start a DMA operation and check status
    # Setup test data at RAM address 0x100
    li x10, 0x00000100
    li x11, 0xAABBCCDD
    sw x11, 0(x10)
    
    # Start SCRATCH.LOAD (funct7=3)
    li x12, 0x00000100      # Source RAM address
    li x13, 0x00000001      # Scratchpad offset 0, length 1 word
    .insn r 0x0B, 0, 3, x0, x12, x13
    
    # Test 3: Poll status - should eventually show done=1, busy=0
    li x14, 0               # Retry counter
    li x15, 10000           # Max retries
    
poll_status:
    # STATUS.READ
    .insn r 0x0B, 0, 5, x4, x0, x0
    
    # Check format: upper 29 bits should be 0
    li x5, 0xFFFFFFF8
    and x6, x4, x5
    bne x6, x0, test_fail
    
    # Check if done (bit 1)
    andi x6, x4, 2
    bne x6, x0, status_done  # If done bit set, check final status
    
    # Check if busy (bit 0)
    andi x6, x4, 1
    beq x6, x0, check_not_busy  # If not busy and not done, something is wrong
    
    # Still busy, continue polling
    addi x14, x14, 1
    blt x14, x15, poll_status
    j test_fail                 # Timeout
    
check_not_busy:
    # Not busy and not done - unexpected state
    j test_fail
    
status_done:
    # Verify final status: done=1, busy=0, error=0
    # Expected: 0x2 (binary: 010)
    li x5, 0x2
    bne x4, x5, test_fail
    
    # Test 4: Start an operation with invalid address (should set error bit)
    li x12, 0x13000000      # Invalid address (TUBE MMIO)
    li x13, 0x00000001      # Length 1 word
    .insn r 0x0B, 0, 3, x0, x12, x13  # SCRATCH.LOAD
    
    # Poll for completion
    li x14, 0
wait_error:
    .insn r 0x0B, 0, 5, x4, x0, x0
    andi x6, x4, 1
    bne x6, x0, check_error_timeout
    j error_done
    
check_error_timeout:
    addi x14, x14, 1
    li x15, 1000
    blt x14, x15, wait_error
    j test_fail
    
error_done:
    # Verify error bit is set (bit 2 = 0x4)
    # Expected: error=1, done=1, busy=0 -> 0x6 (binary: 110)
    li x5, 0x6
    bne x4, x5, test_fail
    
    # All tests passed - write PASS marker
    li x24, 0x04
    li x25, 0x13000000
    sw x24, 0(x25)

test_pass:
    j test_pass

test_fail:
    li x24, 0xFF
    li x25, 0x13000000
    sw x24, 0(x25)
fail_loop:
    j fail_loop
