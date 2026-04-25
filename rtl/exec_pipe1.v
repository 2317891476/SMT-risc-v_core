// =============================================================================
// Module : exec_pipe1
// Description: Execution Pipeline 1 — Integer ALU + Multiplier + AGU (Load/Store)
//   This pipe handles:
//     1) Integer ALU ops (same 1-cycle latency as pipe0, no branch resolution)
//     2) Multiplier ops (3-cycle latency, via mul_unit)
//     3) Address Generation for Load/Store (1-cycle, base + offset)
//
//   The pipe arbitrates between ALU/MUL/AGU based on in_fu and in_mem* signals.
//   Only one sub-unit operates per cycle (guaranteed by scoreboard FU checking).
// =============================================================================
`include "define.v"

module exec_pipe1 #(
    parameter TAG_W = 5
)(
    input  wire               clk,
    input  wire               rstn,

    // ─── Input from Issue / RO stage ────────────────────────────
    input  wire               in_valid,
    input  wire [TAG_W-1:0]   in_tag,
    input  wire [31:0]        in_pc,
    input  wire [31:0]        in_op_a,       // rs1 data (after bypass)
    input  wire [31:0]        in_op_b,       // rs2 data (after bypass)
    input  wire [31:0]        in_imm,
    input  wire [2:0]         in_func3,
    input  wire               in_func7,
    input  wire [2:0]         in_alu_op,
    input  wire [1:0]         in_alu_src1,
    input  wire [1:0]         in_alu_src2,
    input  wire               in_br,         // should always be 0 for pipe1
    input  wire               in_mem_read,
    input  wire               in_mem_write,
    input  wire               in_mem2reg,
    input  wire [4:0]         in_rd,
    input  wire               in_regs_write,
    input  wire [2:0]         in_fu,
    input  wire [0:0]         in_tid,
    input  wire [`METADATA_ORDER_ID_W-1:0] in_order_id,   // Metadata from scoreboard
    input  wire [7:0]         in_epoch,

    // Flush can kill a held memory request before the LSU accepts it.
    input  wire               flush,
    input  wire [0:0]         flush_tid,
    input  wire               flush_order_valid,
    input  wire [`METADATA_ORDER_ID_W-1:0] flush_order_id,

    // ─── ALU / AGU result (1-cycle path) ────────────────────────
    output wire               alu_out_valid,
    output wire [TAG_W-1:0]   alu_out_tag,
    output wire [31:0]        alu_out_result,
    output wire [4:0]         alu_out_rd,
    output wire               alu_out_regs_write,
    output wire [2:0]         alu_out_fu,
    output wire [0:0]         alu_out_tid,

    // ─── Memory interface (to D-TLB / DCache) ──────────────────
    output wire               mem_req_valid,
    input  wire               mem_req_accept,
    output wire               mem_req_wen,     // 1=store, 0=load
    output wire [31:0]        mem_req_addr,    // effective address
    output wire [31:0]        mem_req_wdata,   // store data
    output wire [2:0]         mem_req_func3,   // LB/LH/LW/SB/SH/SW
    output wire [TAG_W-1:0]   mem_req_tag,
    output wire [4:0]         mem_req_rd,
    output wire               mem_req_regs_write,
    output wire [2:0]         mem_req_fu,
    output wire               mem_req_mem2reg,
    output wire [0:0]         mem_req_tid,
    output wire [`METADATA_ORDER_ID_W-1:0] mem_req_order_id,
    output wire [7:0]         mem_req_epoch,

    // ─── Multiplier result (3-cycle path) ───────────────────────
    output wire               mul_out_valid,
    output wire [TAG_W-1:0]   mul_out_tag,
    output wire [31:0]        mul_out_result,
    output wire [4:0]         mul_out_rd,
    output wire               mul_out_regs_write,
    output wire [2:0]         mul_out_fu,
    output wire [0:0]         mul_out_tid,

    // ─── Divider result (33-cycle path) ─────────────────────────
    output wire               div_out_valid,
    output wire [TAG_W-1:0]   div_out_tag,
    output wire [31:0]        div_out_result,
    output wire [4:0]         div_out_rd,
    output wire               div_out_regs_write,
    output wire [2:0]         div_out_fu,
    output wire [0:0]         div_out_tid,
    output wire               div_busy
);

// ─── Routing logic ──────────────────────────────────────────────────────────
wire is_mem_op = in_mem_read || in_mem_write;
wire is_mul_op = (in_fu == `FU_MUL);
wire is_div_op = (in_fu == `FU_DIV);
wire is_alu_op = in_valid && !is_mem_op && !is_mul_op && !is_div_op;

// ─── ALU path (same logic as pipe0 but no branch) ──────────────────────────
wire [3:0] alu_ctrl;

alu_control u_alu_control (
    .alu_op     (in_alu_op  ),
    .func3_code (in_func3   ),
    .func7_code (in_func7   ),
    .alu_ctrl_r (alu_ctrl   )
);

wire [31:0] alu_op_A, alu_op_B;
assign alu_op_A = (in_alu_src1 == `NULL) ? 32'd0 :
                  (in_alu_src1 == `PC)   ? in_pc  : in_op_a;
assign alu_op_B = (in_alu_src2 == `PC_PLUS4) ? 32'd4   :
                  (in_alu_src2 == `IMM)      ? in_imm   : in_op_b;

wire [31:0] alu_result;
wire        alu_br_mark; // unused

alu u_alu (
    .alu_ctrl (alu_ctrl   ),
    .op_A     (alu_op_A   ),
    .op_B     (alu_op_B   ),
    .alu_o    (alu_result ),
    .br_mark  (alu_br_mark)
);

// ─── AGU (Address Generation Unit) ──────────────────────────────────────────
wire [31:0] eff_addr = in_op_a + in_imm;  // base + offset

// ─── MUL Unit ───────────────────────────────────────────────────────────────
mul_unit #(.TAG_W(TAG_W)) u_mul (
    .clk           (clk           ),
    .rstn          (rstn          ),
    .in_valid      (in_valid && is_mul_op),
    .in_tag        (in_tag        ),
    .in_op_a       (in_op_a       ),
    .in_op_b       (in_op_b       ),
    .in_func3      (in_func3      ),
    .in_rd         (in_rd         ),
    .in_regs_write (in_regs_write ),
    .in_fu         (in_fu         ),
    .in_tid        (in_tid        ),
    .out_valid     (mul_out_valid     ),
    .out_tag       (mul_out_tag       ),
    .out_result    (mul_out_result    ),
    .out_rd        (mul_out_rd        ),
    .out_regs_write(mul_out_regs_write),
    .out_fu        (mul_out_fu        ),
    .out_tid       (mul_out_tid       )
);

// ─── DIV Unit ───────────────────────────────────────────────────────────────
div_unit #(.TAG_W(TAG_W)) u_div (
    .clk           (clk           ),
    .rstn          (rstn          ),
    .in_valid      (in_valid && is_div_op),
    .in_tag        (in_tag        ),
    .in_op_a       (in_op_a       ),
    .in_op_b       (in_op_b       ),
    .in_func3      (in_func3      ),
    .in_rd         (in_rd         ),
    .in_regs_write (in_regs_write ),
    .in_fu         (in_fu         ),
    .in_tid        (in_tid        ),
    .out_valid     (div_out_valid     ),
    .out_tag       (div_out_tag       ),
    .out_result    (div_out_result    ),
    .out_rd        (div_out_rd        ),
    .out_regs_write(div_out_regs_write),
    .out_fu        (div_out_fu        ),
    .out_tid       (div_out_tid       ),
    .busy          (div_busy          )
);

// ─── ALU output (INT + AGU share, but only one active at a time) ────────────
// For memory ops: ALU out carries the effective address (used for bypass of rd
// in store-to-load forwarding scenarios, but rd write is deferred to MEM stage)
// Added output registers for proper 1-cycle pipeline timing

reg        alu_out_valid_r;
reg [TAG_W-1:0] alu_out_tag_r;
reg [31:0] alu_out_result_r;
reg [4:0]  alu_out_rd_r;
reg        alu_out_regs_write_r;
reg [2:0]  alu_out_fu_r;
reg [0:0]  alu_out_tid_r;
reg [`METADATA_ORDER_ID_W-1:0] alu_out_order_id_r;
reg [7:0]  alu_out_epoch_r;
reg        mem_req_valid_r;
reg        mem_req_wen_r;
reg [31:0] mem_req_addr_r;
reg [31:0] mem_req_wdata_r;
reg [2:0]  mem_req_func3_r;
reg [TAG_W-1:0] mem_req_tag_r;
reg [4:0]  mem_req_rd_r;
reg        mem_req_regs_write_r;
reg [2:0]  mem_req_fu_r;
reg        mem_req_mem2reg_r;
reg [0:0]  mem_req_tid_r;
reg [`METADATA_ORDER_ID_W-1:0] mem_req_order_id_r;
reg [7:0]  mem_req_epoch_r;
reg        dbg_beacon_wait_reported_r;

wire held_mem_req_flush_kill =
    mem_req_valid_r && flush && (mem_req_tid_r == flush_tid) &&
    (!flush_order_valid || (mem_req_order_id_r > flush_order_id));
wire incoming_mem_req_flush_kill =
    in_valid && is_mem_op && flush && (in_tid == flush_tid) &&
    (!flush_order_valid || (in_order_id > flush_order_id));

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        alu_out_valid_r      <= 1'b0;
        alu_out_tag_r        <= {TAG_W{1'b0}};
        alu_out_result_r     <= 32'd0;
        alu_out_rd_r         <= 5'd0;
        alu_out_regs_write_r <= 1'b0;
        alu_out_fu_r         <= 3'd0;
        alu_out_tid_r        <= 1'b0;
        alu_out_order_id_r   <= {`METADATA_ORDER_ID_W{1'b0}};
        alu_out_epoch_r      <= 8'd0;
        mem_req_valid_r      <= 1'b0;
        mem_req_wen_r        <= 1'b0;
        mem_req_addr_r       <= 32'd0;
        mem_req_wdata_r      <= 32'd0;
        mem_req_func3_r      <= 3'd0;
        mem_req_tag_r        <= {TAG_W{1'b0}};
        mem_req_rd_r         <= 5'd0;
        mem_req_regs_write_r <= 1'b0;
        mem_req_fu_r         <= 3'd0;
        mem_req_mem2reg_r    <= 1'b0;
        mem_req_tid_r        <= 1'b0;
        mem_req_order_id_r   <= {`METADATA_ORDER_ID_W{1'b0}};
        mem_req_epoch_r      <= 8'd0;
        dbg_beacon_wait_reported_r <= 1'b0;
    end else begin
        alu_out_valid_r      <= is_alu_op;
        alu_out_tag_r        <= in_tag;
        alu_out_result_r     <= is_mem_op ? eff_addr : alu_result;
        alu_out_rd_r         <= in_rd;
        alu_out_regs_write_r <= is_alu_op ? in_regs_write : 1'b0;
        alu_out_fu_r         <= in_fu;
        alu_out_tid_r        <= in_tid;
        alu_out_order_id_r   <= in_order_id;
        alu_out_epoch_r      <= in_epoch;

        if (held_mem_req_flush_kill) begin
            mem_req_valid_r <= 1'b0;
            dbg_beacon_wait_reported_r <= 1'b0;
        end else if (mem_req_valid_r && mem_req_accept) begin
            mem_req_valid_r <= 1'b0;
            dbg_beacon_wait_reported_r <= 1'b0;
        end

        if (in_valid && is_mem_op && !incoming_mem_req_flush_kill &&
            (!mem_req_valid_r || mem_req_accept || held_mem_req_flush_kill)) begin
`ifdef VERBOSE_SIM_LOGS
            if (in_mem_write && (eff_addr == `DEBUG_BEACON_EVT_ADDR)) begin
                $display("[DBG_EP1_STORE] t=%0t pc=%h order=%0d tag=%0d addr=%h wdata=%h func3=%0d tid=%0d",
                         $time, in_pc, in_order_id, in_tag, eff_addr, in_op_b, in_func3, in_tid);
            end
`endif
            mem_req_valid_r      <= 1'b1;
            mem_req_wen_r        <= in_mem_write;
            mem_req_addr_r       <= eff_addr;
            mem_req_wdata_r      <= in_op_b;
            mem_req_func3_r      <= in_func3;
            mem_req_tag_r        <= in_tag;
            mem_req_rd_r         <= in_rd;
            mem_req_regs_write_r <= in_regs_write;
            mem_req_fu_r         <= in_fu;
            mem_req_mem2reg_r    <= in_mem2reg;
            mem_req_tid_r        <= in_tid;
            mem_req_order_id_r   <= in_order_id;
            mem_req_epoch_r      <= in_epoch;
            dbg_beacon_wait_reported_r <= 1'b0;
        end else if (in_valid && is_mem_op && mem_req_valid_r && !mem_req_accept &&
                     !held_mem_req_flush_kill && !incoming_mem_req_flush_kill) begin
`ifdef VERBOSE_SIM_LOGS
            $display("[EP1_MEM_HOLD] t=%0t held_order=%0d held_addr=%h new_order=%0d new_addr=%h",
                     $time, mem_req_order_id_r, mem_req_addr_r, in_order_id, eff_addr);
`endif
        end else if (mem_req_valid_r && !mem_req_accept && !held_mem_req_flush_kill &&
                     mem_req_wen_r && (mem_req_addr_r == `DEBUG_BEACON_EVT_ADDR) &&
                     !dbg_beacon_wait_reported_r) begin
`ifdef VERBOSE_SIM_LOGS
            $display("[DBG_EP1_WAIT] t=%0t order=%0d tag=%0d addr=%h wdata=%h func3=%0d tid=%0d",
                     $time, mem_req_order_id_r, mem_req_tag_r, mem_req_addr_r,
                     mem_req_wdata_r, mem_req_func3_r, mem_req_tid_r);
`endif
            dbg_beacon_wait_reported_r <= 1'b1;
        end
    end
end

assign alu_out_valid      = alu_out_valid_r;
assign alu_out_tag        = alu_out_tag_r;
assign alu_out_result     = alu_out_result_r;
assign alu_out_rd         = alu_out_rd_r;
assign alu_out_regs_write = alu_out_regs_write_r;
assign alu_out_fu         = alu_out_fu_r;
assign alu_out_tid        = alu_out_tid_r;

// ─── Memory request output ─────────────────────────────────────────────────
// Hold memory requests until the LSU accepts them. A one-cycle pulse here can be
// dropped whenever the LSU is busy waiting for an earlier load/store response.
assign mem_req_valid      = mem_req_valid_r;
assign mem_req_wen        = mem_req_wen_r;
assign mem_req_addr       = mem_req_addr_r;
assign mem_req_wdata      = mem_req_wdata_r;
assign mem_req_func3      = mem_req_func3_r;
assign mem_req_tag        = mem_req_tag_r;
assign mem_req_rd         = mem_req_rd_r;
assign mem_req_regs_write = mem_req_regs_write_r;
assign mem_req_fu         = mem_req_fu_r;
assign mem_req_mem2reg    = mem_req_mem2reg_r;
assign mem_req_tid        = mem_req_tid_r;
assign mem_req_order_id   = mem_req_order_id_r;
assign mem_req_epoch      = mem_req_epoch_r;

endmodule
