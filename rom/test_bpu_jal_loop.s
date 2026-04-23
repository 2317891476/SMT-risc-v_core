#####################################################################
# test_bpu_jal_loop.s
#
# Purpose:
#   Exercise unconditional JAL at one static PC repeatedly.
#   This is a direct stress for "always taken" uncond jump behavior.
#
# Result layout @ data_seg:
#   +0x00 jal_hit_count   (expect 64)
#   +0x04 pass_flag       (1=pass)
#   +0x08 fail_code       (0=pass, non-zero=fail)
#####################################################################

.section .text
.global _start
_start:
    lui   x3, 0x1            # data base: 0x1000

    addi  x10, x0, 0         # jal_hit_count
    addi  x11, x0, 0         # iter
    addi  x12, x0, 64        # max_iter

jal_loop_head:
    # Static unconditional jump site under test
jal_site:
    jal   x0, jal_target

    # Must never fall-through
    jal   x0, fail_1

jal_target:
    addi  x10, x10, 1
    addi  x11, x11, 1
    blt   x11, x12, jal_loop_head

    # Verify
    addi  x6, x0, 64
    bne   x10, x6, fail_2

    # PASS
    sw    x10, 0(x3)
    addi  x5, x0, 1
    sw    x5, 4(x3)
    sw    x0, 8(x3)
    jal   x0, finish

fail_1:
    sw    x10, 0(x3)
    sw    x0, 4(x3)
    addi  x6, x0, 1
    sw    x6, 8(x3)
    jal   x0, finish

fail_2:
    sw    x10, 0(x3)
    sw    x0, 4(x3)
    addi  x6, x0, 2
    sw    x6, 8(x3)

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
