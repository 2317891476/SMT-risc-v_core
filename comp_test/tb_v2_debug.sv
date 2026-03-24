`timescale 1ns/1ns
`define TB_IROM tb_v2_debug.u_adam_riscv_v2.u_stage_if_v2.u_inst_memory.u_ram_data
`define TB_REGS tb_v2_debug.u_adam_riscv_v2.u_regs_mt
`define TB_DRAM tb_v2_debug.u_adam_riscv_v2.u_stage_mem.u_data_memory.u_ram_data
`define TB_SB tb_v2_debug.u_adam_riscv_v2.u_scoreboard_v2
`define TB_P0 tb_v2_debug.u_adam_riscv_v2.u_exec_pipe0
`define TB_P1 tb_v2_debug.u_adam_riscv_v2.u_exec_pipe1

`define RAM_DEEP 4096

module tb_v2_debug;

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

initial begin
    $dumpfile("tb_v2.vcd");
    $dumpvars(0, tb_v2_debug);
end

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
    $display ($time, "<<Starting V2 debug simulation>>");
    clk = 1'b1;
    rst = 1'b0;
    #100 rst = 1'b1;
end

// Track register write enables directly from regs_mt
always @(posedge clk) begin
    if (rst) begin
        if (tb_v2_debug.u_adam_riscv_v2.u_regs_mt.w_regs_en_0) begin
            $display("WB0: rd=%0d, data=%h", 
                     tb_v2_debug.u_adam_riscv_v2.u_regs_mt.w_regs_addr_0, 
                     tb_v2_debug.u_adam_riscv_v2.u_regs_mt.w_regs_data_0);
        end
        if (tb_v2_debug.u_adam_riscv_v2.u_regs_mt.w_regs_en_1) begin
            $display("WB1: rd=%0d, data=%h", 
                     tb_v2_debug.u_adam_riscv_v2.u_regs_mt.w_regs_addr_1, 
                     tb_v2_debug.u_adam_riscv_v2.u_regs_mt.w_regs_data_1);
        end
    end
end

// Track branch output
always @(posedge clk) begin
    if (rst && `TB_P0.br_ctrl_r) begin
        $display("BRANCH OUT: br_addr=%h, stored_pc=%h", `TB_P0.br_addr_r, `TB_P0.stored_pc);
    end
end

// Wait for result
initial begin
    wait (`TB_DRAM.mem[0] === 32'h04);
    #200ns;
    $display("=== TEST PASSED ===");
    $finish;
end

initial begin
    wait (`TB_DRAM.mem[0] === 32'hFF);
    #200ns;
    $display("=== TEST FAILED ===");
    $finish;
end

initial begin
    #200us;
    $display("Timeout!");
    $display("DRAM[0] = %h", `TB_DRAM.mem[0]);
    $finish;
end

endmodule