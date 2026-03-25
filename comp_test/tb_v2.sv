`timescale 1ns/1ns
`define TB_IROM tb_v2.u_adam_riscv_v2.u_stage_if_v2.u_inst_memory.u_inst_backing_store.u_ram
`define TB_REGS tb_v2.u_adam_riscv_v2.u_regs_mt
`define TB_MEM_SUBSYS tb_v2.u_adam_riscv_v2.u_mem_subsys
`define TUBE_STATUS tb_v2.u_adam_riscv_v2.tube_status

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
// Initialize instruction backing store + shared mem_subsys RAM
//------------------------------------------------------------------------------------------------
initial begin : init_memories
    integer i;
    reg [31:0] inst_word;
    reg [31:0] data_word;

    for (i = 0; i < (`RAM_DEEP*4); i = i + 1) begin
        inst_bytes[i] = 8'd0;
        data_bytes[i] = 8'd0;
    end
    $readmemh("../rom/inst.hex", inst_bytes);
    $readmemh("../rom/data.hex", data_bytes);

    for (i = 0; i < `RAM_DEEP; i = i + 1) begin
        inst_word = {inst_bytes[i*4+3], inst_bytes[i*4+2], inst_bytes[i*4+1], inst_bytes[i*4+0]};
        data_word = {data_bytes[i*4+3], data_bytes[i*4+2], data_bytes[i*4+1], data_bytes[i*4+0]};
        `TB_IROM.mem[i]       = inst_word;
        `TB_MEM_SUBSYS.ram[i] = inst_word | data_word;
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

//------------------------------------------------------------------------------------------------
// PLIC External Interrupt Stimulus
// Drives ext_irq_src for deterministic external interrupt testing
//------------------------------------------------------------------------------------------------
initial begin : plic_stimulus
    // Default: no external interrupt
    force u_adam_riscv_v2.ext_irq_src = 1'b0;
    
    // Wait for reset release
    @(posedge rst);
    
    // For PLIC tests, assert external interrupt after some cycles
    // to allow test setup (enable interrupts, configure PLIC)
    if (`TB_IROM.mem[0] === 32'h00000093) begin  // Detect PLIC test by first instruction
        #5000;  // Wait 5us for test setup
        force u_adam_riscv_v2.ext_irq_src = 1'b1;
        #1000;  // Hold for 1us
        force u_adam_riscv_v2.ext_irq_src = 1'b0;
    end
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
