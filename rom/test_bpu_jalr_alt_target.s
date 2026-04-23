#####################################################################
# test_bpu_jalr_alt_target.s
#
# Purpose:
#   Exercise one static JALR PC while alternating between two targets.
#   Useful to verify indirect-target update/redirect robustness.
#
# Result layout @ data_seg:
#   +0x00 hit_t0      (expect 32)
#   +0x04 hit_t1      (expect 32)
#   +0x08 pass_flag   (1=pass)
#   +0x0C fail_code   (0=pass)
#####################################################################

.section .text
.global _start
_start:
    lui   x3, 0x1

    addi  x10, x0, 0         # hit_t0
    addi  x11, x0, 0         # hit_t1
    addi  x12, x0, 0         # iter
    addi  x13, x0, 64        # max_iter

    la    x21, target_0
    la    x22, target_1

jalr_dispatch:
    # Select target by iter[0]
    andi  x14, x12, 1
    beq   x14, x0, sel_t0
    addi  x20, x22, 0
    jal   x0, do_jalr

sel_t0:
    addi  x20, x21, 0

do_jalr:
jalr_site:
    jalr  x0, x20, 0

    # Must never fall-through
    jal   x0, fail_1

target_0:
    addi  x10, x10, 1
    jal   x0, iter_tail

target_1:
    addi  x11, x11, 1

iter_tail:
    addi  x12, x12, 1
    blt   x12, x13, jalr_dispatch

    # Verify expected split 32/32
    addi  x6, x0, 32
    bne   x10, x6, fail_2
    bne   x11, x6, fail_3

    # PASS
    sw    x10, 0(x3)
    sw    x11, 4(x3)
    addi  x5, x0, 1
    sw    x5, 8(x3)
    sw    x0, 12(x3)
    jal   x0, finish

fail_1:
    sw    x10, 0(x3)
    sw    x11, 4(x3)
    sw    x0, 8(x3)
    addi  x6, x0, 1
    sw    x6, 12(x3)
    jal   x0, finish

fail_2:
    sw    x10, 0(x3)
    sw    x11, 4(x3)
    sw    x0, 8(x3)
    addi  x6, x0, 2
    sw    x6, 12(x3)
    jal   x0, finish

fail_3:
    sw    x10, 0(x3)
    sw    x11, 4(x3)
    sw    x0, 8(x3)
    addi  x6, x0, 3
    sw    x6, 12(x3)

finish:
    lui   x4, 0x13000
    addi  x5, x0, 0x4
    sb    x5, 0(x4)

hang:
    jal   x0, hang

.section .data
.align 4
data_seg:
    .word 0
    .word 0
    .word 0
    .word 0
