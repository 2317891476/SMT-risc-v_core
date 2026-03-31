`timescale 1ns/1ns
`define TB_IROM tb.u_adam_riscv.u_stage_if.u_inst_memory.u_inst_backing_store.u_ram
`define TB_REGS tb.u_adam_riscv.u_regs_mt
`ifdef TB_LEGACY_MEM
`define TB_DATA_MEM tb.u_adam_riscv.gen_legacy_mem.u_legacy_mem_subsys.data_mem
`define TB_MEM_SUBSYS tb.u_adam_riscv.gen_legacy_mem.u_legacy_mem_subsys.data_mem
`else
// Data memory path through mem_subsys (when USE_MEM_SUBSYS=1)
`define TB_DATA_MEM tb.u_adam_riscv.gen_mem_subsys.u_mem_subsys.ram
// For backward compatibility with test_content.sv
`define TB_MEM_SUBSYS tb.u_adam_riscv.gen_mem_subsys.u_mem_subsys.ram
`endif
`define TUBE_STATUS tb.u_adam_riscv.tube_status

`define RAM_DEEP 4096

// RoCC feature guard - set to 1 to enable RoCC monitoring when accelerator is instantiated
`ifndef ROCC_ENABLE
`define ROCC_ENABLE 0
`endif

`ifndef TB_DEBUG
`define TB_DEBUG 0
`endif

// RoCC monitoring hooks (for verification when RoCC is integrated)
// These macros reference RoCC signals for command/response/DMA tracing
`ifndef ROCC_INST_PATH
`define ROCC_INST_PATH tb.u_adam_riscv.u_rocc_ai_accelerator
`endif

// RoCC STATUS.READ result bits (per define.v)
`define ROCC_STATUS_BUSY  0
`define ROCC_STATUS_DONE  1
`define ROCC_STATUS_ERROR 2

module tb;

reg clk;
reg rst;
localparam integer DATA_BASE_WORD = 32'h0000_1000 >> 2;
localparam integer TB_SELECTED_TEST_ID = `TEST_ID;
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
// Wave dump
//------------------------------------------------------------------------------------------------
initial begin
    $dumpfile("tb.vcd");
    $dumpvars(0, tb);
end

//------------------------------------------------------------------------------------------------
// Initialize instruction backing store (from inst.hex)
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
// Initialize mem_subsys RAM (for external refill bypass) - MUST match IROM content
//------------------------------------------------------------------------------------------------
initial begin : init_mem_subsys
    integer i;
    // Wait for inst_bytes to be loaded by init_irom
    #10;
    for (i = 0; i < `RAM_DEEP; i = i + 1) begin
        `TB_MEM_SUBSYS[i] = {inst_bytes[i*4+3], inst_bytes[i*4+2], inst_bytes[i*4+1], inst_bytes[i*4+0]};
    end
    // Verify key words including the TUBE write area
    $display("[MEM_SUBSYS_INIT] ram[24]=%h ram[25]=%h ram[26]=%h ram[27]=%h ram[28]=%h ram[29]=%h", 
             `TB_MEM_SUBSYS[24], `TB_MEM_SUBSYS[25], `TB_MEM_SUBSYS[26],
             `TB_MEM_SUBSYS[27], `TB_MEM_SUBSYS[28], `TB_MEM_SUBSYS[29]);
end



//------------------------------------------------------------------------------------------------
// Initialize legacy data memory (from data.hex)
//------------------------------------------------------------------------------------------------
initial begin : init_dram
    integer i;
    for (i = 0; i < (`RAM_DEEP*4); i = i + 1) begin
        data_bytes[i] = 8'd0;
    end
    $readmemh("../rom/data.hex", data_bytes);

    // mem_subsys uses a unified RAM image. Load the data segment after the
    // instruction image has been mirrored into shared RAM so .data overlays
    // the linker-script region at 0x1000 instead of being clobbered by text.
    #20;
    for (i = DATA_BASE_WORD; i < `RAM_DEEP; i = i + 1) begin
        `TB_DATA_MEM[i] = {data_bytes[i*4+3], data_bytes[i*4+2], data_bytes[i*4+1], data_bytes[i*4+0]};
    end
    $display("[DATA_OVERLAY] ram[1024]=%h ram[1025]=%h ram[1026]=%h ram[1027]=%h",
             `TB_DATA_MEM[1024], `TB_DATA_MEM[1025], `TB_DATA_MEM[1026], `TB_DATA_MEM[1027]);
end

initial begin
    $display ($time, "<<Starting simulation>>");
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
    force u_adam_riscv.ext_irq_src = 1'b0;
    
    // Wait for reset release
    @(posedge rst);
    
    // For PLIC tests, assert external interrupt after some cycles
    // to allow test setup (enable interrupts, configure PLIC)
    if (TB_SELECTED_TEST_ID == 10) begin
        #5000;  // Wait 5us for test setup
        force u_adam_riscv.ext_irq_src = 1'b1;
        #1000;  // Hold for 1us
        force u_adam_riscv.ext_irq_src = 1'b0;
    end else if (TB_SELECTED_TEST_ID == 19) begin
        #5000;  // Wait 5us for test setup
        force u_adam_riscv.ext_irq_src = 1'b1;
        #1000;
        force u_adam_riscv.ext_irq_src = 1'b0;
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

// RoCC command monitoring (when RoCC is instantiated and enabled)
// Tracks commands issued to the RoCC accelerator
generate
if (`ROCC_ENABLE) begin : gen_rocc_monitor
    always @(posedge clk) begin
        if (rst) begin
            rocc_cmd_count <= 32'd0;
        end
        // Check if RoCC instance exists and command is valid
        if (`ROCC_INST_PATH.cmd_valid && `ROCC_INST_PATH.cmd_ready) begin
            rocc_cmd_count <= rocc_cmd_count + 32'd1;
            $display("[RoCC MON] CMD: funct7=%0d funct3=%0d rs1=0x%08h rs2=0x%08h rd=x%0d tag=%0d tid=%0d @%0t",
                     `ROCC_INST_PATH.cmd_funct7, `ROCC_INST_PATH.cmd_funct3,
                     `ROCC_INST_PATH.cmd_rs1_data, `ROCC_INST_PATH.cmd_rs2_data,
                     `ROCC_INST_PATH.cmd_rd, `ROCC_INST_PATH.cmd_tag,
                     `ROCC_INST_PATH.cmd_tid, $time);
            // Track operation start for timeout detection
            if (`ROCC_INST_PATH.cmd_funct7 == 7'd0 || // GEMM.START
                `ROCC_INST_PATH.cmd_funct7 == 7'd3 || // SCRATCH.LOAD
                `ROCC_INST_PATH.cmd_funct7 == 7'd4)   // SCRATCH.STORE
            begin
                rocc_operation_active <= 1'b1;
                rocc_start_cycle <= $time / 50; // Convert to cycle count (20MHz = 50ns)
                rocc_active_cmd_funct7 <= `ROCC_INST_PATH.cmd_funct7;
            end
        end
    end
end
endgenerate

// RoCC response monitoring (when RoCC is instantiated and enabled)
generate
if (`ROCC_ENABLE) begin : gen_rocc_resp_monitor
    always @(posedge clk) begin
        if (rst) begin
            rocc_resp_count <= 32'd0;
        end
        if (`ROCC_INST_PATH.resp_valid && `ROCC_INST_PATH.resp_ready) begin
            rocc_resp_count <= rocc_resp_count + 32'd1;
            $display("[RoCC MON] RESP: data=0x%08h rd=x%0d tag=%0d tid=%0d @%0t",
                     `ROCC_INST_PATH.resp_data, `ROCC_INST_PATH.resp_rd,
                     `ROCC_INST_PATH.resp_tag, `ROCC_INST_PATH.resp_tid, $time);
            // Clear operation active flag on response
            rocc_operation_active <= 1'b0;
        end
    end
end
endgenerate

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
// Debug: Monitor WB signals and ROB state
//---------------------------------------------------------------------------------------------
generate
if (`TB_DEBUG) begin : gen_tb_debug
always @(posedge clk) begin
    if (rst) begin
        // Monitor dispatch
        if (u_adam_riscv.disp0_valid_gated && !u_adam_riscv.sb_disp_stall) begin
            $display("[DISP0] pc=0x%08h fu=%0d tag=%0d ord=%0d rd=%0d tid=%0d @%0t",
                     u_adam_riscv.dec0_pc,
                     u_adam_riscv.dec0_fu,
                     u_adam_riscv.sb_disp0_tag,
                     u_adam_riscv.disp0_order_id,
                     u_adam_riscv.dec0_rd,
                     u_adam_riscv.dec0_tid,
                     $time);
        end
        if (u_adam_riscv.disp1_valid_gated && !u_adam_riscv.sb_disp_stall) begin
            $display("[DISP1] pc=0x%08h fu=%0d tag=%0d ord=%0d rd=%0d tid=%0d @%0t",
                     u_adam_riscv.dec1_pc,
                     u_adam_riscv.dec1_fu,
                     u_adam_riscv.sb_disp1_tag,
                     u_adam_riscv.disp1_order_id,
                     u_adam_riscv.dec1_rd,
                     u_adam_riscv.dec1_tid,
                     $time);
        end
        if (u_adam_riscv.iss0_valid) begin
            $display("[ISS0] pc=0x%08h fu=%0d tag=%0d ord=%0d rd=%0d tid=%0d @%0t",
                     u_adam_riscv.iss0_pc,
                     u_adam_riscv.iss0_fu,
                     u_adam_riscv.iss0_tag,
                     u_adam_riscv.iss0_order_id,
                     u_adam_riscv.iss0_rd,
                     u_adam_riscv.iss0_tid,
                     $time);
            $display("[ISS0 SRC DBG] rs1=x%0d used=%0b src1_tag=%0d ro1=0x%08h tagv=%0b tagd=0x%08h byp_a=0x%08h fwd_a=%0d @%0t",
                     u_adam_riscv.iss0_rs1,
                     u_adam_riscv.iss0_rs1_used,
                     u_adam_riscv.iss0_src1_tag,
                     u_adam_riscv.ro0_data1,
                     u_adam_riscv.p0_tagbuf_a_valid,
                     u_adam_riscv.p0_tagbuf_a_data,
                     u_adam_riscv.byp0_op_a,
                     u_adam_riscv.byp0_fwd_a,
                     $time);
        end
        if (u_adam_riscv.iss1_valid) begin
            $display("[ISS1] pc=0x%08h fu=%0d tag=%0d ord=%0d rd=%0d tid=%0d @%0t",
                     u_adam_riscv.iss1_pc,
                     u_adam_riscv.iss1_fu,
                     u_adam_riscv.iss1_tag,
                     u_adam_riscv.iss1_order_id,
                     u_adam_riscv.iss1_rd,
                     u_adam_riscv.iss1_tid,
                     $time);
            if (u_adam_riscv.iss1_mem_write) begin
                $display("[ISS1 STORE DBG] rs2=x%0d used=%0b src2_tag=%0d ro2=0x%08h byp_b=0x%08h fwd_b=%0d @%0t",
                         u_adam_riscv.iss1_rs2,
                         u_adam_riscv.iss1_rs2_used,
                         u_adam_riscv.iss1_src2_tag,
                         u_adam_riscv.ro1_data2,
                         u_adam_riscv.byp1_op_b,
                         u_adam_riscv.byp1_fwd_b,
                         $time);
            end
        end
        // Monitor exec_pipe1 memory requests
        if (u_adam_riscv.p1_mem_req_valid) begin
            $display("[P1 MEM REQ] addr=0x%08h wen=%0b wdata=0x%08h tag=%0d @%0t",
                     u_adam_riscv.p1_mem_req_addr,
                     u_adam_riscv.p1_mem_req_wen,
                     u_adam_riscv.p1_mem_req_wdata,
                     u_adam_riscv.p1_mem_req_tag,
                     $time);
        end
        // Monitor WB0
        if (u_adam_riscv.wb0_valid) begin
            $display("[WB0] tag=%0d rd=%0d tid=%0d fu=%0d @%0t",
                     u_adam_riscv.wb0_tag,
                     u_adam_riscv.wb0_rd,
                     u_adam_riscv.wb0_tid,
                     u_adam_riscv.wb0_fu,
                     $time);
        end
        // Monitor WB1
        if (u_adam_riscv.wb1_valid) begin
            $display("[WB1] tag=%0d rd=%0d tid=%0d fu=%0d @%0t",
                     u_adam_riscv.wb1_tag,
                     u_adam_riscv.wb1_rd,
                     u_adam_riscv.wb1_tid,
                     u_adam_riscv.wb1_fu,
                     $time);
        end
        if (u_adam_riscv.w_regs_en_0) begin
            $display("[RF W0] tid=%0d rd=%0d data=0x%08h @%0t",
                     u_adam_riscv.w_regs_tid_0,
                     u_adam_riscv.w_regs_addr_0,
                     u_adam_riscv.w_regs_data_0,
                     $time);
        end
        if (u_adam_riscv.w_regs_en_1) begin
            $display("[RF W1] tid=%0d rd=%0d data=0x%08h @%0t",
                     u_adam_riscv.w_regs_tid_1,
                     u_adam_riscv.w_regs_addr_1,
                     u_adam_riscv.w_regs_data_1,
                     $time);
        end
        if (u_adam_riscv.if_valid &&
            (u_adam_riscv.if_pc >= 32'h00000290) &&
            (u_adam_riscv.if_pc <= 32'h00000670)) begin
            $display("[IF] pc=0x%08h inst=0x%08h @%0t",
                     u_adam_riscv.if_pc,
                     u_adam_riscv.if_inst,
                     $time);
        end
        if (u_adam_riscv.pipe0_br_complete || u_adam_riscv.pipe0_br_ctrl) begin
            $display("[BR] complete=%0b taken=%0b tid=%0d order=%0d target=0x%08h @%0t",
                     u_adam_riscv.pipe0_br_complete,
                     u_adam_riscv.pipe0_br_ctrl,
                     u_adam_riscv.pipe0_br_tid,
                     u_adam_riscv.pipe0_br_order_id,
                     u_adam_riscv.pipe0_br_addr,
                     $time);
        end
        if (u_adam_riscv.u_stage_if.fetch_req_launch || (u_adam_riscv.combined_flush != 2'b00)) begin
            $display("[IF CTRL] launch=%0b pc_out=0x%08h pending=0x%08h active=%0b flush=%b @%0t",
                     u_adam_riscv.u_stage_if.fetch_req_launch,
                     u_adam_riscv.u_stage_if.pc_out,
                     u_adam_riscv.u_stage_if.fetch_pc_pending,
                     u_adam_riscv.u_stage_if.fetch_req_active,
                     u_adam_riscv.combined_flush,
                     $time);
        end
        // Monitor store buffer write attempts
        if (u_adam_riscv.sb_mem_write_valid) begin
            $display("[SB WRITE] addr=0x%08h data=0x%08h wen=0x%h @%0t",
                     u_adam_riscv.sb_mem_write_addr,
                     u_adam_riscv.sb_mem_write_data,
                     u_adam_riscv.sb_mem_write_wen,
                     $time);
        end
        // Monitor TUBE status (test completion marker)
        if (u_adam_riscv.tube_status !== 8'b0) begin
            $display("[TUBE STATUS] status=0x%02h @%0t",
                     u_adam_riscv.tube_status,
                     $time);
        end
        // Monitor ROB commits
        if (u_adam_riscv.rob_commit0_valid) begin
            $display("[ROB C0] tag=%0d rd=%0d ord=%0d st=%0b @%0t",
                     u_adam_riscv.rob_commit0_tag,
                     u_adam_riscv.rob_commit0_rd,
                     u_adam_riscv.rob_commit0_order_id,
                     u_adam_riscv.rob_commit0_is_store,
                     $time);
        end
        if (u_adam_riscv.rob_commit1_valid) begin
            $display("[ROB C1] tag=%0d rd=%0d ord=%0d st=%0b @%0t",
                     u_adam_riscv.rob_commit1_tag,
                     u_adam_riscv.rob_commit1_rd,
                     u_adam_riscv.rob_commit1_order_id,
                     u_adam_riscv.rob_commit1_is_store,
                     $time);
        end
        if (($time >= 7000) && ($time <= 7600)) begin
            $display("[STALL DBG] dec0_valid=%0b dec0_pc=0x%08h dec1_valid=%0b dec1_pc=0x%08h stall=%0b rob_stall=%0b sb_stall=%0b rob0_full=%0b rob1_full=%0b @%0t",
                     u_adam_riscv.dec0_valid,
                     u_adam_riscv.dec0_pc,
                     u_adam_riscv.dec1_valid,
                     u_adam_riscv.dec1_pc,
                     u_adam_riscv.stall,
                     u_adam_riscv.rob_disp_stall,
                     u_adam_riscv.sb_disp_stall,
                     u_adam_riscv.rob0_full,
                     u_adam_riscv.rob1_full,
                     $time);
            $display("[ROB WIN DBG] head=%0d tail=%0d count=%0d h_valid=%0b h_complete=%0b h_flushed=%0b h_tag=%0d h_ord=%0d @%0t",
                     u_adam_riscv.u_rob_lite.rob_head[0],
                     u_adam_riscv.u_rob_lite.rob_tail[0],
                     u_adam_riscv.u_rob_lite.rob_count[0],
                     u_adam_riscv.u_rob_lite.rob_valid[0][u_adam_riscv.u_rob_lite.rob_head[0]],
                     u_adam_riscv.u_rob_lite.rob_complete[0][u_adam_riscv.u_rob_lite.rob_head[0]],
                     u_adam_riscv.u_rob_lite.rob_flushed[0][u_adam_riscv.u_rob_lite.rob_head[0]],
                     u_adam_riscv.u_rob_lite.rob_tag[0][u_adam_riscv.u_rob_lite.rob_head[0]],
                     u_adam_riscv.u_rob_lite.rob_order_id[0][u_adam_riscv.u_rob_lite.rob_head[0]],
                     $time);
        end
        if (u_adam_riscv.ext_timer_irq || u_adam_riscv.ext_external_irq ||
            u_adam_riscv.trap_enter || u_adam_riscv.trap_return) begin
            $display("[IRQ DBG] mtip=%0b meip=%0b trap_enter=%0b trap_return=%0b trap_pc=0x%08h trap_target=0x%08h mepc=0x%08h mcause=0x%08h mstatus=0x%08h mie=0x%08h mip=0x%08h mtvec=0x%08h @%0t",
                     u_adam_riscv.ext_timer_irq,
                     u_adam_riscv.ext_external_irq,
                     u_adam_riscv.trap_enter,
                     u_adam_riscv.trap_return,
                     u_adam_riscv.trap_pc_r,
                     u_adam_riscv.trap_target,
                     u_adam_riscv.u_csr_unit.mepc,
                     u_adam_riscv.u_csr_unit.mcause,
                     u_adam_riscv.u_csr_unit.mstatus,
                     u_adam_riscv.u_csr_unit.mie,
                     u_adam_riscv.u_csr_unit.mip,
                     u_adam_riscv.u_csr_unit.mtvec,
                     $time);
        end
        if ((u_adam_riscv.dec0_pc >= 32'h00000054) &&
            (u_adam_riscv.dec0_pc <= 32'h0000005c)) begin
            $display("[ROB DBG] head=%0d tail=%0d count=%0d h_valid=%0b h_complete=%0b h_tag=%0d @%0t",
                     u_adam_riscv.u_rob_lite.rob_head[0],
                     u_adam_riscv.u_rob_lite.rob_tail[0],
                     u_adam_riscv.u_rob_lite.rob_count[0],
                     u_adam_riscv.u_rob_lite.rob_valid[0][u_adam_riscv.u_rob_lite.rob_head[0]],
                     u_adam_riscv.u_rob_lite.rob_complete[0][u_adam_riscv.u_rob_lite.rob_head[0]],
                     u_adam_riscv.u_rob_lite.rob_tag[0][u_adam_riscv.u_rob_lite.rob_head[0]],
                     $time);
            $display("[SB DBG] tag1 valid=%0b issued=%0b ready=%0b qj=%0d qk=%0d | tag2 valid=%0b issued=%0b ready=%0b qj=%0d qk=%0d @%0t",
                     u_adam_riscv.u_scoreboard.win_valid[0],
                     u_adam_riscv.u_scoreboard.win_issued[0],
                     u_adam_riscv.u_scoreboard.win_ready[0],
                     u_adam_riscv.u_scoreboard.win_qj[0],
                     u_adam_riscv.u_scoreboard.win_qk[0],
                     u_adam_riscv.u_scoreboard.win_valid[1],
                     u_adam_riscv.u_scoreboard.win_issued[1],
                     u_adam_riscv.u_scoreboard.win_ready[1],
                     u_adam_riscv.u_scoreboard.win_qj[1],
                     u_adam_riscv.u_scoreboard.win_qk[1],
                     $time);
        end
    end
end
end
endgenerate

//---------------------------------------------------------------------------------------------
// TEST CONTENT (reuse test_content.sv)
//---------------------------------------------------------------------------------------------
`include "test_content.sv"

//---------------------------------------------------------------------------------------------
// Heartbeat counter - verify simulation is advancing
//---------------------------------------------------------------------------------------------
reg [31:0] heartbeat_counter;
initial heartbeat_counter = 32'd0;
always @(posedge clk) begin
    if (rst) begin
        heartbeat_counter <= heartbeat_counter + 32'd1;
        if (heartbeat_counter % 1000 == 0) begin
            $display("[HEARTBEAT] Cycle=%0d PC=0x%08h if_valid=%b if_inst=0x%08h dec0_valid=%b fb_pop0_valid=%b rst=%b @%0t",
                     heartbeat_counter,
                     u_adam_riscv.dec0_pc,
                     u_adam_riscv.if_valid,
                     u_adam_riscv.if_inst,
                     u_adam_riscv.dec0_valid,
                     u_adam_riscv.fb_pop0_valid,
                     rst,
                     $time);
        end
    end
end

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
    $display("========= Test PASS !!! %d",$time);
    $display("==================================================================");
    $finish;
endtask

task    TEST_FAIL;
    $display("==================================================================");
    $display("=========     FFFFFFF       A         III   L         ============");
    $display("=========     FFFFFFF    AAAAAAA       I    L         ============");
    $display("=========     F       A           A   III   LLLLLLL   ============");
    $display("==================================================================");
    $display("========= Test FAILED !!! %d",$time);
    $display("==================================================================");
    $finish;
endtask


endmodule
