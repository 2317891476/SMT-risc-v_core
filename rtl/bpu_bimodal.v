// =============================================================================
// Module : bpu_bimodal
// Description: Bimodal branch predictor with 2-bit saturating counters.
//   - 256-entry PHT (Pattern History Table), indexed by PC[9:2]
//   - Provides a taken/not-taken prediction at IF stage
//   - Updated at EX/WB when the branch outcome is resolved
//   - Per-thread: each thread indexes independently (thread-interleaved)
//
// Prediction latency: 0 cycles (combinational lookup, fed to IF mux)
// Update latency: 1 cycle (registered update from EX/WB)
// =============================================================================
`include "define.v"

module bpu_bimodal #(
    parameter PHT_ENTRIES = 256,             // number of 2-bit counters
    parameter PHT_IDX_W   = $clog2(PHT_ENTRIES)
)(
    input  wire               clk,
    input  wire               rstn,

    // ─── Prediction Port (combinational, used at IF stage) ──────
    input  wire [31:0]        pred_pc,        // PC of instruction being fetched
    input  wire [0:0]         pred_tid,       // thread ID (for thread-indexed PHT)
    output wire               pred_taken,     // predicted direction: 1=taken, 0=not-taken
    output wire [31:0]        pred_target,    // predicted target from BTB when hit
    output wire               pred_hit,       // BTB hit for this PC
    output wire [1:0]         pred_type,      // predicted entry type

    // ─── Update Port (from EX/WB stage, 1 cycle latent) ─────────
    input  wire               resolve_valid,   // a resolved branch is being reported
    input  wire [31:0]        resolve_pc,      // PC of the resolved branch
    input  wire [0:0]         resolve_tid,     // thread ID of the resolved branch
    input  wire               resolve_taken,   // actual outcome: 1=taken, 0=not-taken
    input  wire [31:0]        resolve_target,  // actual branch target address
    input  wire [1:0]         resolve_type     // conditional / jal / jalr
);

// ─── PHT: 2-bit saturating counters ─────────────────────────────────────────
// Encoding: 2'b00 = Strongly Not-Taken (SNT)
//           2'b01 = Weakly   Not-Taken (WNT)
//           2'b10 = Weakly   Taken     (WT)
//           2'b11 = Strongly Taken     (ST)
reg [1:0] pht [0:PHT_ENTRIES-1];

// ─── BTB: simple direct-mapped target cache (matches PHT index) ─────────────
reg [31:0] btb_target [0:PHT_ENTRIES-1];
reg        btb_valid  [0:PHT_ENTRIES-1];
reg [31-PHT_IDX_W-2:0] btb_tag [0:PHT_ENTRIES-1];
reg [1:0]              btb_type[0:PHT_ENTRIES-1];
reg                     btb_tid [0:PHT_ENTRIES-1];

// ─── Index functions ────────────────────────────────────────────────────────
wire [PHT_IDX_W-1:0] pred_idx;
wire [PHT_IDX_W-1:0] upd_idx;
wire [31-PHT_IDX_W-2:0] pred_tag;
wire [31-PHT_IDX_W-2:0] upd_tag;

// XOR fold PC with thread ID for better distribution
assign pred_idx = pred_pc[PHT_IDX_W+1:2] ^ {{(PHT_IDX_W-1){1'b0}}, pred_tid};
assign upd_idx  = resolve_pc[PHT_IDX_W+1:2] ^ {{(PHT_IDX_W-1){1'b0}}, resolve_tid};
assign pred_tag = pred_pc[31:PHT_IDX_W+2];
assign upd_tag  = resolve_pc[31:PHT_IDX_W+2];

// ─── Prediction (combinational) ─────────────────────────────────────────────
assign pred_hit    = btb_valid[pred_idx] &&
                     (btb_tag[pred_idx] == pred_tag) &&
                     (btb_tid[pred_idx] == pred_tid);
assign pred_type   = pred_hit ? btb_type[pred_idx] : `BPU_TYPE_COND;
assign pred_taken  = !pred_hit ? 1'b0 :
                     (pred_type == `BPU_TYPE_COND) ? pht[pred_idx][1] : 1'b1;
assign pred_target = pred_hit ? btb_target[pred_idx] : (pred_pc + 32'd4);

// ─── Update (registered) ────────────────────────────────────────────────────
integer i;

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        for (i = 0; i < PHT_ENTRIES; i = i + 1) begin
            pht[i]        <= 2'b01;   // Initialize to Weakly Not-Taken
            btb_target[i] <= 32'd0;
            btb_valid[i]  <= 1'b0;
            btb_tag[i]    <= {(30-PHT_IDX_W){1'b0}};
            btb_type[i]   <= `BPU_TYPE_COND;
            btb_tid[i]    <= 1'b0;
        end
    end
    else begin
        if (resolve_valid) begin
            if (resolve_type == `BPU_TYPE_COND) begin
                if (resolve_taken) begin
                    if (pht[upd_idx] != 2'b11)
                        pht[upd_idx] <= pht[upd_idx] + 2'd1;
                end
                else begin
                    if (pht[upd_idx] != 2'b00)
                        pht[upd_idx] <= pht[upd_idx] - 2'd1;
                end
            end

            if (resolve_taken || (resolve_type != `BPU_TYPE_COND)) begin
                btb_target[upd_idx] <= resolve_target;
                btb_valid[upd_idx]  <= 1'b1;
                btb_tag[upd_idx]    <= upd_tag;
                btb_type[upd_idx]   <= resolve_type;
                btb_tid[upd_idx]    <= resolve_tid;
            end
        end
    end
end

endmodule
