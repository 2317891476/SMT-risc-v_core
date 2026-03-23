`timescale 1ns/1ns
`define TB_IROM tb_v2.u_adam_riscv_v2.u_stage_if_v2.u_inst_memory.u_ram_data
`define TB_REGS tb_v2.u_adam_riscv_v2.u_regs_mt
`define TB_DRAM tb_v2.u_adam_riscv_v2.u_stage_mem.u_data_memory.u_ram_data

`define RAM_DEEP 4096

module tb_v2;

reg clk;
reg rst;
always begin
#25    clk = ~clk;
end

reg [7:0] inst_bytes [0:(`RAM_DEEP*4)-1];
reg [7:0] data_bytes [0:(`RAM_DEEP*4)-1];
integer j;

adam_riscv_v2 u_adam_riscv_v2(
    .sys_clk  (clk ),
    .sys_rstn (rst )
);

//------------------------------------------------------------------------------------------------
// Wave dump
//------------------------------------------------------------------------------------------------
initial begin
    $dumpfile("tb_v2.vcd");
    $dumpvars(0, tb_v2);
end

//------------------------------------------------------------------------------------------------
// initial Instruction ROM
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
// initial Data RAM
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
    $display ($time, "<<Starting V2 simulation>>");
    for(j=0; j<50; j=j+1)
        $display("%d: %h", j, `TB_IROM.mem[j]);
    clk = 1'b1;
    rst = 1'b0;
    #100 rst = 1'b1;
end

//---------------------------------------------------------------------------------------------
// TEST CONTENT (reuse test_content.sv)
//---------------------------------------------------------------------------------------------
`include "test_content.sv"

//---------------------------------------------------------------------------------------------
// show test result
//---------------------------------------------------------------------------------------------
task    TEST_PASS;
    $display("==================================================================");
    $display("=========   PPPPPPPP       A        SSSSS    SSSSS     ===========");
    $display("=========    P      P     A A      S     S  S     S    ===========");
    $display("=========    PPPPPP     AAAAAAA     SSSSS    SSSSS     ===========");
    $display("=========    P        A         A        S        S    ===========");
    $display("=========    P       A           A  SSSSS    SSSSS     ===========");
    $display("==================================================================");
    $display("========= V2 case PASS !!! %d",$time);
    $display("==================================================================");
    $finish;
endtask

task    TEST_FAIL;
    $display("==================================================================");
    $display("=========     FFFFFFF       A         III   L         ============");
    $display("=========     FFFFFFF    AAAAAAA       I    L         ============");
    $display("=========     F       A           A   III   LLLLLLL   ============");
    $display("==================================================================");
    $display("========= V2 case FAILED !!! %d",$time);
    $display("==================================================================");
    $finish;
endtask


endmodule
