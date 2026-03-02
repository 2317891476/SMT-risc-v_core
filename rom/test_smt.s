##########################################################
# test_smt.s  -  SMT smoke test for AdamRiscv (strict RV32I)
#
# Both threads use STRAIGHT-LINE code only (no branches).
# This avoids speculative-store issues with the OoO scheduler.
#
# Thread 0 (boot PC = 0x0000):
#   Computes 1+2+3+4+5+6+7+8+9+10 = 55 = 0x37  (unrolled adds)
#   sw -> DRAM[1152]  (byte addr 0x1200)
#   sb 0x04 -> TUBE  (wraps to DRAM[0][7:0] = 0x04)
#
# Thread 1 (boot PC = 0x0800):
#   Computes 10+10+10 = 30 = 0x1E  (3 unrolled adds)
#   sw -> DRAM[1153]  (byte addr 0x1204)
##########################################################

.section .text
.global _start

# ============================================================
# Thread 0  (PC = 0x0000)  - sum 1..10 = 55, straight-line
# ============================================================
_start:
    lui  x4, 1                # x4 = 0x1000  (DRAM base)
    lui  x6, 0x13000          # x6 = 0x13000000  (TUBE)
    addi x7, x0, 4            # end marker = 0x4

    # Unrolled sum: x1 = 1+2+...+10 = 55 = 0x37
    addi x1, x0,  1           # x1 = 1
    addi x1, x1,  2           # x1 = 3
    addi x1, x1,  3           # x1 = 6
    addi x1, x1,  4           # x1 = 10
    addi x1, x1,  5           # x1 = 15
    addi x1, x1,  6           # x1 = 21+
    addi x1, x1,  7           # x1 = 28
    addi x1, x1,  8           # x1 = 36
    addi x1, x1,  9           # x1 = 45
    addi x1, x1,  10          # x1 = 55

    sw   x1, 0x200(x4)        # DRAM[1152] = 55
    nop ; nop ; nop ; nop
    nop ; nop ; nop ; nop
    sb   x7, 0(x6)            # TUBE trigger

_t0_dead:
    nop ; nop ; nop ; nop
    nop ; nop ; nop ; nop

# ============================================================
# Thread 1  (PC = 0x0800)  - 10*3 = 30, straight-line
# ============================================================
.org 0x800
_t1_start:
    lui  x4, 1                 # x4 = 0x1000  (DRAM base)

    # Unrolled 10*3 = 30 = 0x1E
    addi x1, x0,  0            # x1 = 0
    addi x1, x1,  10           # x1 = 10
    addi x1, x1,  10           # x1 = 20
    addi x1, x1,  10           # x1 = 30

    sw   x1, 0x204(x4)         # DRAM[1153] = 30

_t1_dead:
    nop ; nop ; nop ; nop
    nop ; nop ; nop ; nop

# ============================================================
.data
data_seg:
    .word 0x00000000
    .word 0x00000000
    .word 0x00000000
    .word 0x00000000
