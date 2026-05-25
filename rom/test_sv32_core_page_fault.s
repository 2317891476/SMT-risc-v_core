.section .text
.globl _start

.include "p2_mmio.inc"

# Core-level Sv32 D-side page-fault smoke:
# - Build page tables that map code and MMIO but leave VA 0x1000 unmapped.
# - Enter S-mode with load/store page faults delegated to S-mode.
# - Trigger load and store page faults and verify scause/stval/sepc in stvec.

.equ L0_PT_BASE,      0x00002000
.equ ROOT_PT_BASE,    0x00003000
.equ CODE_FLAGS,      0x000000CF  # V/R/W/X/A/D
.equ MMIO_FLAGS,      0x000000C7  # V/R/W/A/D
.equ SATP_SV32_ROOT3, 0x80000003

_start:
    # root[0] -> second-level table at PPN=2
    li x1, ROOT_PT_BASE
    li x2, ((L0_PT_BASE >> 12) << 10) | 0x1
    sw x2, 0(x1)

    # root[0x4c] -> 0x1300_0000 MMIO 4MB megapage for PASS/FAIL writes.
    li x2, ((TUBE_ADDR >> 12) << 10) | MMIO_FLAGS
    li x3, (TUBE_ADDR >> 22) * 4
    add x3, x1, x3
    sw x2, 0(x3)

    # l0[0] identity maps code/page-table page 0 as executable.
    li x1, L0_PT_BASE
    li x2, CODE_FLAGS
    sw x2, 0(x1)

    # Keep the page-table pages mapped. Leave l0[1] unmapped on purpose.
    li x2, (2 << 10) | CODE_FLAGS
    sw x2, 8(x1)
    li x2, (3 << 10) | CODE_FLAGS
    sw x2, 12(x1)

    la x5, s_trap_handler
    csrw stvec, x5
    li x6, 0x0000A000      # delegate load/store page faults
    csrw medeleg, x6

    li x4, SATP_SV32_ROOT3
    csrw satp, x4
    .word 0x12000073      # sfence.vma x0, x0

    la x5, supervisor_entry
    csrw mepc, x5
    li x6, 0x00000880      # MPP=S, MPIE=1
    csrw mstatus, x6
    mret

    j test_fail

supervisor_entry:
    li x20, 0
    li x10, 0x00001000

fault_load:
    lw x21, 0(x10)
after_load_fault:
    li x22, 1
    bne x20, x22, test_fail

fault_store:
    sw x22, 0(x10)
after_store_fault:
    li x22, 2
    bne x20, x22, test_fail

    li x16, 0x04
    li x17, TUBE_ADDR
    sw x16, 0(x17)

test_pass:
    j test_pass

test_fail:
    li x16, 0xFF
    li x17, TUBE_ADDR
    sw x16, 0(x17)
fail_loop:
    j fail_loop

s_trap_handler:
    csrr x23, scause
    csrr x24, stval
    li x25, 0x00001000
    bne x24, x25, test_fail
    csrr x26, sepc

    beq x20, x0, handle_load_fault
    li x27, 1
    beq x20, x27, handle_store_fault
    j test_fail

handle_load_fault:
    li x27, 13
    bne x23, x27, test_fail
    la x28, fault_load
    bne x26, x28, test_fail
    addi x26, x26, 4
    csrw sepc, x26
    li x20, 1
    sret

handle_store_fault:
    li x27, 15
    bne x23, x27, test_fail
    la x28, fault_store
    bne x26, x28, test_fail
    addi x26, x26, 4
    csrw sepc, x26
    li x20, 2
    sret
