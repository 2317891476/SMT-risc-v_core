.section .text
.globl _start

# Test: RoCC DMA Test (test_id=13)
# Verifies SCRATCH.LOAD and SCRATCH.STORE operations
# 
# Test sequence:
#   1. Write test pattern to RAM at source address
#   2. SCRATCH.LOAD: DMA from RAM to scratchpad
#   3. SCRATCH.STORE: DMA from scratchpad to different RAM location
#   4. Verify data was copied correctly
#   5. STATUS.READ to verify operation completed without error

_start:
    # Mark test as RoCC DMA test (test_id=13 marker: addi x3, x0, 13)
    li x3, 13
    
    # Setup: Write test pattern to RAM at address 0x100 (word-aligned)
    # We'll write 8 words of test data
    li x10, 0x00000100      # Source address in RAM
    li x11, 0x11111111
    sw x11, 0(x10)
    li x11, 0x22222222
    sw x11, 4(x10)
    li x11, 0x33333333
    sw x11, 8(x10)
    li x11, 0x44444444
    sw x11, 12(x10)
    li x11, 0x55555555
    sw x11, 16(x10)
    li x11, 0x66666666
    sw x11, 20(x10)
    li x11, 0x77777777
    sw x11, 24(x10)
    li x11, 0x88888888
    sw x11, 28(x10)
    
    # Test 1: SCRATCH.LOAD
    # Load 8 words from RAM (0x100) to scratchpad (offset 0)
    # rs1 = source RAM address (0x100)
    # rs2 = {scratchpad_offset[15:0], length[15:0]} = {0, 8}
    li x12, 0x00000100      # Source RAM address
    li x13, 0x00000008      # Scratchpad offset 0, length 8 words
    
    # Custom-0 opcode with funct7=3 (SCRATCH.LOAD)
    # .insn r opcode, funct3, funct7, rd, rs1, rs2
    .insn r 0x0B, 0, 3, x0, x12, x13
    
    # Wait for LOAD to complete (poll STATUS.READ)
    li x14, 0               # Retry counter
wait_load:
    # STATUS.READ (funct7=5)
    .insn r 0x0B, 0, 5, x3, x0, x0
    
    # Check if busy bit (bit 0) is clear
    andi x15, x3, 1
    bne x15, x0, check_load_timeout
    
    # Check if error bit (bit 2) is set
    andi x15, x3, 4
    bne x15, x0, test_fail
    
    j load_done
    
check_load_timeout:
    addi x14, x14, 1
    li x15, 10000
    blt x14, x15, wait_load
    j test_fail             # Timeout
    
load_done:
    # Test 2: SCRATCH.STORE
    # Store 8 words from scratchpad (offset 0) to RAM (0x200)
    # rs1 = scratchpad offset (0)
    # rs2 = {dest_RAM_addr[15:0], length[15:0]} = {0x200, 8}
    li x12, 0               # Scratchpad source offset
    li x13, 0x02000008      # Dest RAM addr 0x200, length 8 words
    
    # Custom-0 opcode with funct7=4 (SCRATCH.STORE)
    .insn r 0x0B, 0, 4, x0, x12, x13
    
    # Wait for STORE to complete
    li x14, 0               # Retry counter
wait_store:
    # STATUS.READ (funct7=5)
    .insn r 0x0B, 0, 5, x3, x0, x0
    
    # Check if busy bit (bit 0) is clear
    andi x15, x3, 1
    bne x15, x0, check_store_timeout
    
    # Check if error bit (bit 2) is set
    andi x15, x3, 4
    bne x15, x0, test_fail
    
    j store_done
    
check_store_timeout:
    addi x14, x14, 1
    li x15, 10000
    blt x14, x15, wait_store
    j test_fail             # Timeout
    
store_done:
    # Test 3: Verify data was copied correctly
    # Read from destination (0x200) and verify against expected values
    li x10, 0x00000200      # Destination address
    
    lw x16, 0(x10)
    li x17, 0x11111111
    bne x16, x17, test_fail
    
    lw x16, 4(x10)
    li x17, 0x22222222
    bne x16, x17, test_fail
    
    lw x16, 8(x10)
    li x17, 0x33333333
    bne x16, x17, test_fail
    
    lw x16, 12(x10)
    li x17, 0x44444444
    bne x16, x17, test_fail
    
    lw x16, 16(x10)
    li x17, 0x55555555
    bne x16, x17, test_fail
    
    lw x16, 20(x10)
    li x17, 0x66666666
    bne x16, x17, test_fail
    
    lw x16, 24(x10)
    li x17, 0x77777777
    bne x16, x17, test_fail
    
    lw x16, 28(x10)
    li x17, 0x88888888
    bne x16, x17, test_fail
    
    # Test 4: Test error detection - try DMA to invalid address (MMIO region)
    # This should set the error bit in status
    li x12, 0x13000000      # Invalid address (TUBE MMIO)
    li x13, 0x00000001      # Scratchpad offset 0, length 1 word
    
    # SCRATCH.LOAD from invalid address
    .insn r 0x0B, 0, 3, x0, x12, x13
    
    # Wait for operation
    li x14, 0
wait_error:
    .insn r 0x0B, 0, 5, x3, x0, x0
    andi x15, x3, 1
    bne x15, x0, check_error_timeout
    j error_check_done
    
check_error_timeout:
    addi x14, x14, 1
    li x15, 1000
    blt x14, x15, wait_error
    j test_fail
    
error_check_done:
    # Check that error bit (bit 2) is set
    andi x15, x3, 4
    beq x15, x0, test_fail  # Error bit should be set
    
    # All tests passed - write PASS marker to TUBE
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
