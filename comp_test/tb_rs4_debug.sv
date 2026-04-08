`timescale 1ns/1ns
`include "tb.sv"
// Use standard tb but add debug check after tube fires
initial begin
    wait (tb.u_adam_riscv.tube_status === 8'h04);
    #200ns;
    $display("=== RS4 DEBUG CHECKS (test2) ===");
    $display("x0  = %h (expect 00000000)", `TB_REGS.reg_bank[0][0]);
    $display("x1  = %h (expect 00000015)", `TB_REGS.reg_bank[0][1]);
    $display("x2  = %h (expect 0000002a)", `TB_REGS.reg_bank[0][2]);
    $display("x3  = %h (expect 00001000)", `TB_REGS.reg_bank[0][3]);
    $display("x4  = %h (expect 13000000)", `TB_REGS.reg_bank[0][4]);
    $display("x5  = %h (expect 00000004)", `TB_REGS.reg_bank[0][5]);
    $display("x6  = %h (expect 00000015)", `TB_REGS.reg_bank[0][6]);
    $display("x7  = %h (expect 0000003f)", `TB_REGS.reg_bank[0][7]);
    $display("x8  = %h (expect 0000003f)", `TB_REGS.reg_bank[0][8]);
    $display("x9  = %h (expect f3f2f21a)", `TB_REGS.reg_bank[0][9]);
    $display("tube= %h (expect 04)", tb.u_adam_riscv.tube_status);
    $display("mem[1024]=%h (expect f3f2f21a)", `TB_MEM_SUBSYS[1024]);
    $display("mem[1025]=%h (expect f7f6f5f4)", `TB_MEM_SUBSYS[1025]);
end
