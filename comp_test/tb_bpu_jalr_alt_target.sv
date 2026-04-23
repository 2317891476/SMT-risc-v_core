`timescale 1ns/1ns
`define TB_IROM tb_bpu_jalr_alt_target.u_adam_riscv.u_stage_if.u_inst_memory.u_inst_backing_store.u_ram
`ifdef TB_LEGACY_MEM
`define TB_DATA_MEM tb_bpu_jalr_alt_target.u_adam_riscv.gen_legacy_mem.u_legacy_mem_subsys.data_mem
`define TB_MEM_SUBSYS tb_bpu_jalr_alt_target.u_adam_riscv.gen_legacy_mem.u_legacy_mem_subsys.data_mem
`else
`define TB_DATA_MEM tb_bpu_jalr_alt_target.u_adam_riscv.gen_mem_subsys.u_mem_subsys.ram
`define TB_MEM_SUBSYS tb_bpu_jalr_alt_target.u_adam_riscv.gen_mem_subsys.u_mem_subsys.ram
`endif
`define TUBE_STATUS tb_bpu_jalr_alt_target.u_adam_riscv.tube_status
`define RAM_DEEP 4096

module tb_bpu_jalr_alt_target;
reg clk;
reg rst;
wire core_uart_tx;
localparam integer DATA_BASE_WORD = 32'h0000_1000 >> 2;

reg [7:0] inst_bytes [0:(`RAM_DEEP*4)-1];
reg [7:0] data_bytes [0:(`RAM_DEEP*4)-1];
integer i;

adam_riscv u_adam_riscv(
    .sys_clk  (clk),
    .sys_rstn (rst),
    .uart_rx  (1'b1),
    .uart_tx  (core_uart_tx)
);

always begin
    #25 clk = ~clk;
end

initial begin
    $dumpfile("tb_bpu_jalr_alt_target.vcd");
    $dumpvars(0, tb_bpu_jalr_alt_target);
end

initial begin : init_irom
    for (i = 0; i < (`RAM_DEEP*4); i = i + 1) begin
        inst_bytes[i] = 8'd0;
    end
    $readmemh("../rom/test_bpu_jalr_alt_target.inst.hex", inst_bytes);

    for (i = 0; i < `RAM_DEEP; i = i + 1) begin
        `TB_IROM.mem[i] = {inst_bytes[i*4+3], inst_bytes[i*4+2], inst_bytes[i*4+1], inst_bytes[i*4+0]};
    end
end

initial begin : init_mem_subsys
    #10;
    for (i = 0; i < `RAM_DEEP; i = i + 1) begin
        `TB_MEM_SUBSYS[i] = {inst_bytes[i*4+3], inst_bytes[i*4+2], inst_bytes[i*4+1], inst_bytes[i*4+0]};
    end
end

initial begin : init_dram
    for (i = 0; i < (`RAM_DEEP*4); i = i + 1) begin
        data_bytes[i] = 8'd0;
    end
    $readmemh("../rom/test_bpu_jalr_alt_target.data.hex", data_bytes);

    #20;
    for (i = DATA_BASE_WORD; i < `RAM_DEEP; i = i + 1) begin
        `TB_DATA_MEM[i] = {data_bytes[i*4+3], data_bytes[i*4+2], data_bytes[i*4+1], data_bytes[i*4+0]};
    end
end

initial begin
    clk = 1'b1;
    rst = 1'b0;
    #100 rst = 1'b1;
end

task show_results;
    begin
        $display("[BPU_JALR_ALT] hit_t0    = %0d", `TB_MEM_SUBSYS[DATA_BASE_WORD + 0]);
        $display("[BPU_JALR_ALT] hit_t1    = %0d", `TB_MEM_SUBSYS[DATA_BASE_WORD + 1]);
        $display("[BPU_JALR_ALT] pass_flag = %0d", `TB_MEM_SUBSYS[DATA_BASE_WORD + 2]);
        $display("[BPU_JALR_ALT] fail_code = %0d", `TB_MEM_SUBSYS[DATA_BASE_WORD + 3]);
    end
endtask

task test_pass;
    begin
        $display("==================================================================");
        $display("[BPU_JALR_ALT] PASS");
        show_results;
        $display("==================================================================");
        $finish;
    end
endtask

task test_fail;
    input [255:0] reason;
    begin
        $display("==================================================================");
        $display("[BPU_JALR_ALT] FAIL: %0s", reason);
        show_results;
        $display("==================================================================");
        $finish;
    end
endtask

initial begin
    wait (`TUBE_STATUS === 8'h04);
    #200ns;

    if (`TB_MEM_SUBSYS[DATA_BASE_WORD + 0] !== 32'd32)
        test_fail("hit_t0 mismatch");
    if (`TB_MEM_SUBSYS[DATA_BASE_WORD + 1] !== 32'd32)
        test_fail("hit_t1 mismatch");
    if (`TB_MEM_SUBSYS[DATA_BASE_WORD + 2] !== 32'd1)
        test_fail("pass_flag mismatch");
    if (`TB_MEM_SUBSYS[DATA_BASE_WORD + 3] !== 32'd0)
        test_fail("fail_code mismatch");

    test_pass;
end

initial begin
    #300us;
    test_fail("timeout waiting for TUBE 0x04");
end

endmodule
