`timescale 1ns/1ns
`define TB_IROM tb.u_adam_riscv.u_stage_if.u_inst_memory.u_ram_data
`define TB_REGS tb.u_adam_riscv.u_stage_ro.u_regs_mt
`define TB_DRAM tb.u_adam_riscv.u_stage_mem.u_data_memory.u_ram_data

`define RAM_DEEP 4096


module tb;

reg clk;
reg rst;
always begin
#25    clk = ~clk;
end

reg [7:0] inst_bytes [0:(`RAM_DEEP*4)-1];
reg [7:0] data_bytes [0:(`RAM_DEEP*4)-1];
integer j;

adam_riscv u_adam_riscv(
    .sys_clk  (clk ),
    .sys_rstn (rst )
);

//------------------------------------------------------------------------------------------------
// Wave dump (default VCD for iverilog/gtkwave)
//------------------------------------------------------------------------------------------------
initial begin
    $dumpfile("tb.vcd");
    $dumpvars(0, tb);
end


//------------------------------------------------------------------------------------------------
// initial Instruction ROM: load from .text (inst.hex)
//------------------------------------------------------------------------------------------------
initial begin : init_irom
    integer i;
    for (i = 0; i < (`RAM_DEEP*4); i = i + 1) begin
        inst_bytes[i] = 8'd0;
    end
    $readmemh("../rom/inst.hex", inst_bytes);

    for (i = 0; i < `RAM_DEEP; i = i + 1) begin
        `TB_IROM.mem[i] = {inst_bytes[i*4+3], inst_bytes[i*4+2], inst_bytes[i*4+1], inst_bytes[i*4+0]};
    end
end

//------------------------------------------------------------------------------------------------
// initial Data RAM: load from .data (data.hex)
//------------------------------------------------------------------------------------------------
initial begin : init_dram
    integer i;
    for (i = 0; i < (`RAM_DEEP*4); i = i + 1) begin
        data_bytes[i] = 8'd0;
    end
    $readmemh("../rom/data.hex", data_bytes);

    for (i = 0; i < `RAM_DEEP; i = i + 1) begin
        `TB_DRAM.mem[i] = {data_bytes[i*4+3], data_bytes[i*4+2], data_bytes[i*4+1], data_bytes[i*4+0]};
    end
end

initial begin
    $display ($time, "<<Starting simulation>>");
    for(j=0; j<200; j=j+1)
        $display("%d: %h", j, `TB_IROM.mem[j]);
    clk = 1'b1;
    rst = 1'b0;
    #100 rst = 1'b1;

end

//---------------------------------------------------------------------------------------------
// TEST CONTENT
//---------------------------------------------------------------------------------------------
`include "test_content.sv"

//---------------------------------------------------------------------------------------------
// show test result
//---------------------------------------------------------------------------------------------
task    TEST_PASS;
    $display("==================================================================");
    $display("==================================================================");
    $display("=========                                              ===========");
    $display("=========   PPPPPPPP       A        SSSSS    SSSSS     ===========");
    $display("=========    P      P     A A      S     S  S     S    ===========");
    $display("=========    P      P    A   A     S        S          ===========");
    $display("=========    PPPPPP     AAAAAAA     SSSSS    SSSSS     ===========");
    $display("=========    P         A       A         S        S    ===========");
    $display("=========    P        A         A        S        S    ===========");
    $display("=========    P       A           A  SSSSS    SSSSS     ===========");
    $display("==================================================================");
    $display("========= This case is pass !!! %d",$time);
    $display("==================================================================");
    
    $finish;
endtask


task    TEST_FAIL;

    $display("==================================================================");
    $display("==================================================================");
    $display("=========                                             ============");
    $display("=========     FFFFFFF       A         III   L         ============");
    $display("=========     F            A A         I    L         ============");
    $display("=========     F           A   A        I    L         ============");
    $display("=========     FFFFFFF    AAAAAAA       I    L         ============");
    $display("=========     F         A       A      I    L         ============");
    $display("=========     F        A         A     I    L         ============");
    $display("=========     F       A           A   III   LLLLLLL   ============");
    $display("==================================================================");
    $display("========= This case is failed !!! %d",$time);
    $display("==================================================================");
    
    $finish;
endtask


endmodule
