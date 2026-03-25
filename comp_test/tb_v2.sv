`timescale 1ns/1ns
`define TB_IROM tb_v2.u_adam_riscv_v2.u_stage_if_v2.u_inst_memory.u_inst_backing_store.u_ram
`define TB_REGS tb_v2.u_adam_riscv_v2.u_regs_mt
`define TB_MEM_SUBSYS tb_v2.u_adam_riscv_v2.u_mem_subsys
`define TUBE_STATUS tb_v2.u_adam_riscv_v2.tube_status

`define RAM_DEEP 4096

// RoCC monitoring hooks (for verification when RoCC is integrated)
// These macros reference RoCC signals for command/response/DMA tracing
`ifndef ROCC_INST_PATH
`define ROCC_INST_PATH tb_v2.u_adam_riscv_v2.u_rocc_ai_accelerator
`endif

// RoCC STATUS.READ result bits (per define_v2.v)
`define ROCC_STATUS_BUSY  0
`define ROCC_STATUS_DONE  1
`define ROCC_STATUS_ERROR 2

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

//------------------------------------------------------------------------------------------------
// RoCC Command/Response Monitor
// Tracks RoCC operations for verification when RoCC AI accelerator is integrated
//------------------------------------------------------------------------------------------------
// RoCC operation tracking variables
reg [31:0] rocc_cmd_count;
reg [31:0] rocc_resp_count;
reg [31:0] rocc_dma_rd_count;
reg [31:0] rocc_dma_wr_count;
reg [31:0] rocc_status_read_value;
reg        rocc_status_read_done;
reg [31:0] rocc_start_cycle;
reg        rocc_operation_active;
reg [6:0]  rocc_active_cmd_funct7;

initial begin
    rocc_cmd_count         = 32'd0;
    rocc_resp_count        = 32'd0;
    rocc_dma_rd_count      = 32'd0;
    rocc_dma_wr_count      = 32'd0;
    rocc_status_read_value = 32'd0;
    rocc_status_read_done  = 1'b0;
    rocc_operation_active  = 1'b0;
    rocc_active_cmd_funct7 = 7'd0;
end

// RoCC command monitoring (when RoCC is instantiated)
// Tracks commands issued to the RoCC accelerator
always @(posedge clk) begin
    if (rst) begin
        rocc_cmd_count <= 32'd0;
    end
    // Check if RoCC instance exists and command is valid
    // Hierarchical reference to be enabled when RoCC is integrated:
    // if (`ROCC_INST_PATH.cmd_valid && `ROCC_INST_PATH.cmd_ready) begin
    //     rocc_cmd_count <= rocc_cmd_count + 32'd1;
    //     $display("[RoCC MON] CMD: funct7=%0d funct3=%0d rs1=0x%08h rs2=0x%08h rd=x%0d tag=%0d tid=%0d @%0t",
    //              `ROCC_INST_PATH.cmd_funct7, `ROCC_INST_PATH.cmd_funct3,
    //              `ROCC_INST_PATH.cmd_rs1_data, `ROCC_INST_PATH.cmd_rs2_data,
    //              `ROCC_INST_PATH.cmd_rd, `ROCC_INST_PATH.cmd_tag,
    //              `ROCC_INST_PATH.cmd_tid, $time);
    //     // Track operation start for timeout detection
    //     if (`ROCC_INST_PATH.cmd_funct7 == 7'd0 || // GEMM.START
    //         `ROCC_INST_PATH.cmd_funct7 == 7'd3 || // SCRATCH.LOAD
    //         `ROCC_INST_PATH.cmd_funct7 == 7'd4)   // SCRATCH.STORE
    //     begin
    //         rocc_operation_active <= 1'b1;
    //         rocc_start_cycle <= $time / 50; // Convert to cycle count (20MHz = 50ns)
    //         rocc_active_cmd_funct7 <= `ROCC_INST_PATH.cmd_funct7;
    //     end
    // end
end

// RoCC response monitoring
always @(posedge clk) begin
    if (rst) begin
        rocc_resp_count <= 32'd0;
    end
    // Hierarchical reference to be enabled when RoCC is integrated:
    // if (`ROCC_INST_PATH.resp_valid && `ROCC_INST_PATH.resp_ready) begin
    //     rocc_resp_count <= rocc_resp_count + 32'd1;
    //     $display("[RoCC MON] RESP: data=0x%08h rd=x%0d tag=%0d tid=%0d @%0t",
    //              `ROCC_INST_PATH.resp_data, `ROCC_INST_PATH.resp_rd,
    //              `ROCC_INST_PATH.resp_tag, `ROCC_INST_PATH.resp_tid, $time);
    //     // Clear operation active flag on response
    //     rocc_operation_active <= 1'b0;
    // end
end

// RoCC DMA transaction monitoring
always @(posedge clk) begin
    if (rst) begin
        rocc_dma_rd_count <= 32'd0;
        rocc_dma_wr_count <= 32'd0;
    end
    // DMA read request
    // if (`ROCC_INST_PATH.mem_req_valid && `ROCC_INST_PATH.mem_req_ready &&
    //     !`ROCC_INST_PATH.mem_req_wen) begin
    //     rocc_dma_rd_count <= rocc_dma_rd_count + 32'd1;
    //     $display("[RoCC DMA] RD: addr=0x%08h @%0t", `ROCC_INST_PATH.mem_req_addr, $time);
    // end
    // DMA write request
    // if (`ROCC_INST_PATH.mem_req_valid && `ROCC_INST_PATH.mem_req_ready &&
    //     `ROCC_INST_PATH.mem_req_wen) begin
    //     rocc_dma_wr_count <= rocc_dma_wr_count + 32'd1;
    //     $display("[RoCC DMA] WR: addr=0x%08h data=0x%08h @%0t",
    //              `ROCC_INST_PATH.mem_req_addr, `ROCC_INST_PATH.mem_req_wdata, $time);
    // end
end

// RoCC status read capture (monitors x3 for STATUS.READ results)
// When a RoCC STATUS.READ instruction completes, the result is written to x3
always @(posedge clk) begin
    // Detect when x3 is written with RoCC status (check decode for STATUS.READ)
    // This is a heuristic: RoCC instructions use custom-0 opcode (0x0B)
    // STATUS.READ has funct7=5
    if (!rst && `TB_REGS.reg_bank[0][3] !== 32'dx) begin
        // Check if lower 3 bits match RoCC status pattern {error, done, busy}
        // and upper bits are zero (as per STATUS.READ format)
        if ((`TB_REGS.reg_bank[0][3][31:3] == 29'd0) && 
            (`TB_REGS.reg_bank[0][3][2:0] != 3'd0)) begin
            rocc_status_read_value <= `TB_REGS.reg_bank[0][3];
            rocc_status_read_done  <= 1'b1;
        end
    end
end

// RoCC operation timeout check
// Maximum cycles for RoCC operations before declaring timeout
`define ROCC_MAX_CYCLES 100000

reg [31:0] rocc_timeout_cycle;
reg        rocc_timeout_triggered;

initial begin
    rocc_timeout_cycle    = 32'd0;
    rocc_timeout_triggered = 1'b0;
end

always @(posedge clk) begin
    if (rst) begin
        rocc_timeout_cycle <= 32'd0;
    end
    else if (rocc_operation_active) begin
        rocc_timeout_cycle <= rocc_timeout_cycle + 32'd1;
        if (rocc_timeout_cycle >= `ROCC_MAX_CYCLES && !rocc_timeout_triggered) begin
            rocc_timeout_triggered <= 1'b1;
            $display("[RoCC TIMEOUT] Operation funct7=%0d exceeded max cycles (%0d) @%0t",
                     rocc_active_cmd_funct7, `ROCC_MAX_CYCLES, $time);
        end
    end
    else begin
        rocc_timeout_cycle <= 32'd0;
    end
end

// RoCC accelerator status monitoring
always @(posedge clk) begin
    // if (!rst) begin
    //     // Log accelerator busy/idle transitions
    //     if (`ROCC_INST_PATH.accel_busy !== 1'bx) begin
    //         $display("[RoCC STATUS] accel_busy=%0b @%0t", `ROCC_INST_PATH.accel_busy, $time);
    //     end
    // end
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
