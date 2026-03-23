#####################################################
#test for scoreboard 
#####################################################

.section .text
.global _start
_start:

   # initialize registers
   li x1, 0x15  #addi x1, x0, 0x15
   li x2, 0x2a  #addi x2, x0,0x2a
   li x4, 0x0    #addi x4, x0, 0x0
   # set base address for data access
   # la x3, data_seg is broken, use lui instead
   lui x3, 0x1        # x3 = 0x1000
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
   add x4, x1, x2
   sub x5, x1, x4   
   and x6, x1, x4
   or   x7, x1, x2
   xor x8, x1, x2
   lw x5, 0(x3)
   add x9, x5, x2
   sw x9, 0(x3)
   lw x9, 0(x3)
  
_finish:
    # initialize TUBE address
    li x4,   0x13000000 #lui x4, 0x13000
    # send CTRL+D to TUBE to indicate test is finished
    li x5, 0x4 #addi x5, x0, 0x4
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


.data
data_seg:
.word 0xf3f2f1f0
.word 0xf7f6f5f4
.word 0xfbfaf9f8
.word 0xfffefdfc


