.section .text
.globl _start

.include "p2_mmio.inc"

# Core-level Sv32 integration smoke:
# - Build page tables in local physical RAM while still in M-mode.
# - Enter S-mode with satp.MODE=Sv32.
# - Fetch through an identity-mapped code page.
# - Store/load through a D-side translated data page whose PTE starts with A/D
#   clear, forcing the PTW writeback path. A/D is verified in the standalone
#   MMU test; this core test avoids reading the PTE back through L2 because the
#   integrated cache-coherence policy for PTW writeback is not finished yet.
# - Execute SFENCE.VMA in M-mode and S-mode to smoke the commit-ordered TLB
#   flush path.
# - Write PASS through an identity-mapped 0x1300_0000 MMIO megapage.

.equ L0_PT_BASE,      0x00002000
.equ ROOT_PT_BASE,    0x00003000
.equ CODE_FLAGS,      0x000000CF  # V/R/W/X/A/D
.equ DATA_FLAGS_COLD, 0x00000007  # V/R/W, A/D cleared on purpose
.equ MMIO_FLAGS,      0x000000C7  # V/R/W/A/D
.equ SATP_SV32_ROOT3, 0x80000003

_start:
    # root[0] -> second-level table at PPN=2
    li x1, ROOT_PT_BASE
    li x2, ((L0_PT_BASE >> 12) << 10) | 0x1
    sw x2, 0(x1)

    # root[0x4c] -> 0x1300_0000 MMIO 4MB megapage.
    li x2, ((TUBE_ADDR >> 12) << 10) | MMIO_FLAGS
    li x3, (TUBE_ADDR >> 22) * 4
    add x3, x1, x3
    sw x2, 0(x3)

    # l0[0] identity maps code/page-table page 0 as executable.
    li x1, L0_PT_BASE
    li x2, CODE_FLAGS
    sw x2, 0(x1)

    # l0[1] maps data page 0x1000 with A/D clear to exercise PTW writeback.
    li x2, (1 << 10) | DATA_FLAGS_COLD
    sw x2, 4(x1)

    # Keep the page-table pages mapped too so S-mode can inspect them if needed.
    li x2, (2 << 10) | CODE_FLAGS
    sw x2, 8(x1)
    li x2, (3 << 10) | CODE_FLAGS
    sw x2, 12(x1)

    li x4, SATP_SV32_ROOT3
    csrw satp, x4
    .word 0x12000073      # sfence.vma x0, x0

    la x5, supervisor_entry
    csrw mepc, x5
    li x6, 0x00000880      # MPP=S, MPIE=1
    csrw mstatus, x6
    mret

    j fail_mret

supervisor_entry:
    li x10, 0x00001000
    li x11, 0x5A5AA55A
    sw x11, 0(x10)
    lw x12, 0(x10)
    bne x11, x12, fail_data
    .word 0x12000073      # sfence.vma x0, x0

    li x16, 0x04
    li x17, TUBE_ADDR
    sw x16, 0(x17)

test_pass:
    j test_pass

fail_mret:
    li x16, 0xF1
    li x17, TUBE_ADDR
    sw x16, 0(x17)
fail_mret_loop:
    j fail_mret_loop

fail_data:
    li x16, 0xF2
    li x17, TUBE_ADDR
    sw x16, 0(x17)
fail_data_loop:
    j fail_data_loop
