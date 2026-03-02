#####################################################
#test execution latency for ADD, SUB, AND, OR, XOR, LW and SW
#####################################################

.section .text
.global _start
_start:

   # initialize x1 and x2
   li x1, 0x1  #addi x1, x0, 0x1
   li x2, 0x2  #addi x2, x0, 0x2
   # set base address for data access
   la x3, data_seg #auipc, addi
   # remove RAW hazard
   nop
   nop
   nop
   nop
   nop
   nop
   nop
   nop

main:
   add  x4, x1, x2
   sub  x5, x1, x2
   and  x6, x1, x2
   or     x7, x1, x2
   xor  x8, x1, x2
   lw x9, 0(x3)
   sw x1, 0(x3)
  
_finish:
    # initialize TUBE address
    li x4,   0x13000000 #lui x4, 0x13000
    # send CTRL+D to TUBE to indicate test is finished
    addi x5, x0, 0x4
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    sb x5, 0(x4)
    #dead loop
    #beq x0, x0, _finish
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop

.data
data_seg:
.word 0xf3f2f1f0
.word 0xf7f6f5f4
.word 0xfbfaf9f8
.word 0xfffefdfc


