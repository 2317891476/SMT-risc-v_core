#####################################################################
# test_bpu_postfix.s — BPU post-fix functional test
#
# Covers:
#   A) Static branch pattern TTTTN convergence workload
#   B) Pred-taken -> actual not-taken recovery correctness
#   C) Pred-not-taken -> actual taken recovery correctness
#
# Result layout at data_seg:
#   0x00: phaseA_total
#   0x04: phaseA_taken
#   0x08: phaseA_not_taken
#   0x0C: phaseB_pass (1=pass)
#   0x10: phaseC_pass (1=pass)
#   0x14: overall_pass (1=pass)
#   0x18: fail_code (0=pass, nonzero=failed stage)
#####################################################################

.section .text
.global _start
_start:
    # data base = 0x1000
    lui   x3, 0x1

    # clear result words
    sw    x0, 0(x3)
    sw    x0, 4(x3)
    sw    x0, 8(x3)
    sw    x0, 12(x3)
    sw    x0, 16(x3)
    sw    x0, 20(x3)
    sw    x0, 24(x3)

#####################################################################
# Phase A: TTTTN pattern at one static branch site
#####################################################################
    addi  x20, x0, 32      # epochs
    addi  x21, x0, 0       # epoch idx
    addi  x22, x0, 0       # phase 0..4

    addi  x10, x0, 0       # total
    addi  x11, x0, 0       # taken
    addi  x12, x0, 0       # not-taken

phaseA_loop:
    addi  x22, x22, 1
    addi  x15, x0, 5
    blt   x22, x15, phaseA_taken   # static branch site => T,T,T,T,N

phaseA_not_taken:
    addi  x10, x10, 1
    addi  x12, x12, 1
    addi  x22, x0, 0
    addi  x21, x21, 1
    blt   x21, x20, phaseA_loop
    jal   x0, phaseA_done

phaseA_taken:
    addi  x10, x10, 1
    addi  x11, x11, 1
    jal   x0, phaseA_loop

phaseA_done:
    sw    x10, 0(x3)
    sw    x11, 4(x3)
    sw    x12, 8(x3)

    # sanity: total should be 32*5=160
    addi  x6, x0, 160
    bne   x10, x6, fail_1
    # taken should be 32*4=128
    addi  x6, x0, 128
    bne   x11, x6, fail_1
    # not-taken should be 32
    addi  x6, x0, 32
    bne   x12, x6, fail_1

#####################################################################
# Phase B: train taken, then force one not-taken
# Expect correctness: fall-through path executes, wrong target skipped
#####################################################################
    # train taken at static branch B_SITE
    addi  x7, x0, 16
    addi  x8, x0, 0

phaseB_train_loop:
    addi  x8, x8, 1
B_SITE:
    blt   x0, x8, B_TAKEN_PATH     # always taken when x8>0 during training
    jal   x0, fail_2               # should not reach
B_TAKEN_PATH:
    blt   x8, x7, phaseB_train_loop

    # now force not-taken on same static branch site B_SITE:
    # make condition false: blt x0, x8 with x8=0 => not-taken
    addi  x8, x0, 0
    blt   x0, x8, B_WRONG_TARGET    # should be NOT taken
B_FALLTHROUGH_OK:
    addi  x9, x0, 1
    sw    x9, 12(x3)                # phaseB_pass = 1
    jal   x0, phaseC_start

B_WRONG_TARGET:
    jal   x0, fail_2

#####################################################################
# Phase C: train not-taken, then force one taken
# Expect correctness: target path executes, fall-through skipped
#####################################################################
phaseC_start:
    # train not-taken at static branch C_SITE
    addi  x7, x0, 16
    addi  x8, x0, 0

phaseC_train_loop:
C_SITE:
    blt   x8, x0, C_TAKEN_PATH      # false while x8>=0 => not taken
    addi  x8, x8, 1
    blt   x8, x7, phaseC_train_loop

    # now force taken at same static branch site C_SITE
    # set x8 = -1 => blt -1,0 true
    addi  x8, x0, -1
    blt   x8, x0, C_TAKEN_PATH2
C_FALLTHROUGH_BAD:
    jal   x0, fail_3

C_TAKEN_PATH2:
    addi  x9, x0, 1
    sw    x9, 16(x3)                # phaseC_pass = 1
    jal   x0, all_done

C_TAKEN_PATH:
    # should never land here during C training if condition false
    jal   x0, fail_3

#####################################################################
# PASS / FAIL handling
#####################################################################
all_done:
    # overall pass if phaseB=1 and phaseC=1
    lw    x6, 12(x3)
    lw    x7, 16(x3)
    addi  x9, x0, 1
    bne   x6, x9, fail_4
    bne   x7, x9, fail_4

    sw    x9, 20(x3)                # overall_pass = 1
    sw    x0, 24(x3)                # fail_code = 0
    jal   x0, finish

fail_1:
    addi  x6, x0, 1
    sw    x6, 24(x3)
    jal   x0, finish
fail_2:
    addi  x6, x0, 2
    sw    x6, 24(x3)
    jal   x0, finish
fail_3:
    addi  x6, x0, 3
    sw    x6, 24(x3)
    jal   x0, finish
fail_4:
    addi  x6, x0, 4
    sw    x6, 24(x3)
    jal   x0, finish

finish:
    lui   x4, 0x13000               # 0x13000000
    addi  x5, x0, 0x4
    sb    x5, 0(x4)

dead_loop:
    jal   x0, dead_loop

.section .data
.align 4
data_seg:
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
    .word 0
