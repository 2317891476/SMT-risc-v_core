.section .text
.globl _start

.include "p2_mmio.inc"

# Linux bring-up privilege smoke:
# - misa reports RV32IMA
# - MRET can enter S-mode through mstatus.MPP=S
# - S-mode CSR aliases are readable/writable
# - SRET redirects through sepc and restores SPP/SIE state

_start:
    csrr x1, misa
    li x2, 0x40001101
    bne x1, x2, test_fail

    la x16, s_trap_handler
    csrw stvec, x16
    li x17, 0x00000200
    csrw medeleg, x17

    la x3, supervisor_entry
    csrw mepc, x3

    # MPP=S (01), MPIE=1 so MRET is well-defined.
    li x4, 0x00000880
    csrw mstatus, x4
    mret

    # MRET must not fall through.
    j test_fail

supervisor_entry:
    li x5, 0x13572468
    csrw sscratch, x5
    csrr x6, sscratch
    bne x5, x6, test_fail

    # Keep satp.MODE=0 in this privilege smoke. Sv32 MODE=1 is covered by
    # dedicated MMU tests that install page tables before enabling translation.
    li x7, 0x00000001
    csrw satp, x7
    csrr x8, satp
    bne x7, x8, test_fail

    li x20, 0
    ecall
after_s_ecall:
    li x21, 1
    bne x20, x21, test_fail

    la x9, after_sret
    csrw sepc, x9

    # Set SPP=1 and SPIE=1. SRET should return to S-mode at sepc.
    li x10, 0x00000120
    csrs sstatus, x10
    sret

    # SRET must redirect to after_sret.
    j test_fail

after_sret:
    csrr x11, sstatus
    li x12, 0x00000100
    and x13, x11, x12
    bne x13, x0, test_fail

    li x14, 0x04
    li x15, TUBE_ADDR
    sw x14, 0(x15)

test_pass:
    j test_pass

test_fail:
    li x14, 0xFF
    li x15, TUBE_ADDR
    sw x14, 0(x15)
fail_loop:
    j fail_loop

s_trap_handler:
    csrr x22, scause
    li x23, 9
    bne x22, x23, test_fail
    csrr x24, sepc
    addi x24, x24, 4
    csrw sepc, x24
    li x20, 1
    sret
