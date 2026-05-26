.section .text
.globl _start

.include "p2_mmio.inc"

# Core-level Sv32 I-side page-fault smoke:
# - Build page tables that map code and MMIO but leave VA 0x1000 unmapped.
# - Enter S-mode with instruction page faults delegated to S-mode.
# - Jump to the unmapped VA and verify scause/stval/sepc in the S-mode handler.

.equ L0_PT_BASE,      0x00002000
.equ ROOT_PT_BASE,    0x00003000
.equ CODE_FLAGS,      0x000000CF  # V/R/W/X/A/D
.equ MMIO_FLAGS,      0x000000C7  # V/R/W/A/D
.equ SATP_SV32_ROOT3, 0x80000003
.equ FAULT_PC,        0x00001000

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

    # Keep page-table pages mapped. Leave l0[1] invalid on purpose.
    li x2, (2 << 10) | CODE_FLAGS
    sw x2, 8(x1)
    li x2, (3 << 10) | CODE_FLAGS
    sw x2, 12(x1)

    la x5, s_trap_handler
    csrw stvec, x5
    li x6, 0x00001000      # delegate instruction page fault
    csrw medeleg, x6

    li x4, SATP_SV32_ROOT3
    csrw satp, x4
    .word 0x12000073      # sfence.vma x0, x0

    la x5, supervisor_entry
    csrw mepc, x5
    li x6, 0x00000880      # MPP=S, MPIE=1
    csrw mstatus, x6
    mret

    j fail_mret_fallthrough

supervisor_entry:
    li x20, 0
    li x10, FAULT_PC
    jalr x0, 0(x10)

after_fetch_fault:
    li x21, 1
    bne x20, x21, fail_no_handler_mark

    li x16, 0x04
    li x17, TUBE_ADDR
    sw x16, 0(x17)

test_pass:
    j test_pass

fail_mret_fallthrough:
    li x16, 0xF1
    li x17, TUBE_ADDR
    sw x16, 0(x17)
fail_mret_loop:
    j fail_mret_loop

fail_no_handler_mark:
    li x16, 0xF2
    li x17, TUBE_ADDR
    sw x16, 0(x17)
fail_no_handler_loop:
    j fail_no_handler_loop

fail_scause:
    li x16, 0xF3
    li x17, TUBE_ADDR
    sw x16, 0(x17)
fail_scause_loop:
    j fail_scause_loop

fail_stval:
    li x16, 0xF4
    li x17, TUBE_ADDR
    sw x16, 0(x17)
fail_stval_loop:
    j fail_stval_loop

fail_sepc:
    li x16, 0xFF
    li x17, TUBE_ADDR
    sw x16, 0(x17)
fail_sepc_loop:
    j fail_sepc_loop

s_trap_handler:
    csrr x22, scause
    li x23, 12
    bne x22, x23, fail_scause

    csrr x24, stval
    li x25, FAULT_PC
    bne x24, x25, fail_stval

    csrr x26, sepc
    bne x26, x25, fail_sepc

    la x27, after_fetch_fault
    csrw sepc, x27
    li x20, 1
    sret
