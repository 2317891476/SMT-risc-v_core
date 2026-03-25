.section .text
.globl _start

# Test: CSR/MRET Smoke Test
# Verifies basic CSR operations and MRET instruction
# This is a minimal smoke test for CSR functionality

_start:
    # Test 1: Read mstatus (should be 0x1800 after reset - MPP=M-mode)
    csrr x1, mstatus
    li x2, 0x00001800
    bne x1, x2, test_fail

    # Test 2: Write to mscratch (CSRRW)
    li x3, 0xDEADBEEF
    csrrw x4, mscratch, x3
    # x4 should have old mscratch value (0)
    bne x4, x0, test_fail
    # Verify write by reading back
    csrr x5, mscratch
    bne x5, x3, test_fail

    # Test 3: Set bits in mscratch using CSRRS
    li x6, 0x0000FFFF
    csrrs x7, mscratch, x6
    # x7 should have old value (0xDEADBEEF)
    bne x7, x3, test_fail
    # New value should be 0xDEADBEEF | 0x0000FFFF = 0xDEADFFFF
    csrr x8, mscratch
    li x9, 0xDEADFFFF
    bne x8, x9, test_fail

    # Test 4: Clear bits in mscratch using CSRRC
    li x10, 0xDEAD0000
    csrrc x11, mscratch, x10
    # x11 should have old value (0xDEADFFFF)
    bne x11, x9, test_fail
    # New value should be 0xDEADFFFF & ~0xDEAD0000 = 0x0000FFFF
    csrr x12, mscratch
    bne x12, x6, test_fail

    # Test 5: Set up mtvec (trap vector)
    la x13, trap_handler
    csrw mtvec, x13
    csrr x14, mtvec
    # mtvec should be aligned to 4 bytes
    andi x15, x14, 0x3
    bne x15, x0, test_fail

    # Test 6: Test MRET by triggering a trap and returning
    # Set mepc to the address after the trap
    la x16, after_trap
    csrw mepc, x16
    
    # Trigger an ECALL (which will cause a trap)
    ecall

after_trap:
    # If we get here, MRET worked correctly
    
    # Test 7: Test CSR immediate instructions
    li x17, 0
    csrw mscratch, x17      # Clear mscratch
    
    # CSRRSI - set bits with immediate
    csrrsi x18, mscratch, 5 # Set bits 0 and 2 (value 5)
    bne x18, x0, test_fail  # Old value was 0
    csrr x19, mscratch
    li x20, 5
    bne x19, x20, test_fail
    
    # CSRRCI - clear bits with immediate
    csrrci x21, mscratch, 1 # Clear bit 0
    li x22, 4
    bne x21, x20, test_fail # Old value was 5
    csrr x23, mscratch
    bne x23, x22, test_fail

    # All tests passed
    li x24, 0x04
    li x25, 0x13000000  # TUBE address
    sw x24, 0(x25)      # Write PASS marker

test_pass:
    j test_pass

test_fail:
    li x24, 0xFF        # FAIL marker
    li x25, 0x13000000
    sw x24, 0(x25)
fail_loop:
    j fail_loop

# Trap handler
trap_handler:
    # Save mepc
    csrr x30, mepc
    
    # For ECALL, increment mepc by 4 to skip the ECALL instruction
    addi x30, x30, 4
    csrw mepc, x30
    
    # Return from trap
    mret