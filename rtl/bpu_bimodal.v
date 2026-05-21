// =============================================================================
// Module : bpu_bimodal
// Description: Bimodal branch predictor with 2-bit saturating counters.
//   - PHT (Pattern History Table), indexed by PC
//   - Provides a taken/not-taken prediction at IF stage
//   - Updated at EX/WB when the branch outcome is resolved
//   - RAS (Return Address Stack) for call/return prediction
//
// Prediction latency: 0 cycles (combinational lookup, fed to IF mux)
// Update latency: 1 cycle (registered update from EX/WB)
// =============================================================================
module bpu_bimodal #(
    parameter PHT_ENTRIES = 256,
    parameter PHT_IDX_W   = $clog2(PHT_ENTRIES),
    parameter RAS_DEPTH   = 8,
    parameter RAS_IDX_W   = $clog2(RAS_DEPTH)
)(
    input  wire               clk,
    input  wire               rstn,

    // Prediction Port (combinational, used at IF stage)
    input  wire [31:0]        pred_pc,
    output wire               pred_taken,
    output wire [31:0]        pred_target,

    // Update Port (from EX/WB stage, 1 cycle latent)
    input  wire               update_valid,
    input  wire [31:0]        update_pc,
    input  wire               update_taken,
    input  wire [31:0]        update_target,
    input  wire               update_is_call,
    input  wire               update_is_return
);

// PHT: 2-bit saturating counters
reg [1:0] pht [0:PHT_ENTRIES-1];

// BTB: simple direct-mapped target cache
localparam BTB_TAG_W = 32 - PHT_IDX_W - 2;

reg [31:0] btb_target [0:PHT_ENTRIES-1];
reg [BTB_TAG_W-1:0] btb_tag [0:PHT_ENTRIES-1];
reg        btb_valid  [0:PHT_ENTRIES-1];
reg        btb_is_return [0:PHT_ENTRIES-1];

// Single RAS
reg [31:0] ras_target [0:RAS_DEPTH-1];
reg [RAS_IDX_W-1:0] ras_sp;
reg [RAS_IDX_W:0]   ras_count;

// Index functions
wire [PHT_IDX_W-1:0] pred_idx;
wire [PHT_IDX_W-1:0] upd_idx;
wire [BTB_TAG_W-1:0] pred_tag;
wire [BTB_TAG_W-1:0] upd_tag;
wire                 btb_hit;
wire                 pred_is_return;
wire                 ras_pred_valid;
wire [RAS_IDX_W-1:0] ras_top_idx;

assign pred_idx = pred_pc[PHT_IDX_W+1:2];
assign upd_idx  = update_pc[PHT_IDX_W+1:2];
assign pred_tag = pred_pc[31:PHT_IDX_W+2];
assign upd_tag  = update_pc[31:PHT_IDX_W+2];
assign btb_hit  = btb_valid[pred_idx] && (btb_tag[pred_idx] == pred_tag);
assign pred_is_return = btb_hit && btb_is_return[pred_idx];
assign ras_pred_valid = (ras_count != {(RAS_IDX_W+1){1'b0}});
assign ras_top_idx = ras_sp - {{(RAS_IDX_W-1){1'b0}}, 1'b1};

// Prediction (combinational)
assign pred_taken  = btb_hit && (btb_is_return[pred_idx] || pht[pred_idx][1]);
assign pred_target = (pred_is_return && ras_pred_valid) ? ras_target[ras_top_idx] :
                     btb_hit ? btb_target[pred_idx] : (pred_pc + 32'd4);


// Update (registered)
integer i;
integer ri;

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        for (i = 0; i < PHT_ENTRIES; i = i + 1) begin
            pht[i]        <= 2'b10;
            btb_target[i] <= 32'd0;
            btb_tag[i]    <= {BTB_TAG_W{1'b0}};
            btb_valid[i]  <= 1'b0;
            btb_is_return[i] <= 1'b0;
        end
        ras_sp <= {RAS_IDX_W{1'b0}};
        ras_count <= {(RAS_IDX_W+1){1'b0}};
        for (ri = 0; ri < RAS_DEPTH; ri = ri + 1) begin
            ras_target[ri] <= 32'd0;
        end
    end
    else begin
        if (update_valid) begin
            if (update_taken) begin
                if (pht[upd_idx] != 2'b11)
                    pht[upd_idx] <= pht[upd_idx] + 2'd1;
            end
            else begin
                if (pht[upd_idx] != 2'b00)
                    pht[upd_idx] <= pht[upd_idx] - 2'd1;
            end

            if (update_taken) begin
                btb_target[upd_idx] <= update_target;
                btb_tag[upd_idx]    <= upd_tag;
                btb_valid[upd_idx]  <= 1'b1;
                btb_is_return[upd_idx] <= update_is_return;
            end

            if (update_taken && update_is_call) begin
                ras_target[ras_sp] <= update_pc + 32'd4;
                ras_sp <= ras_sp + {{(RAS_IDX_W-1){1'b0}}, 1'b1};
                if (ras_count != RAS_DEPTH[RAS_IDX_W:0])
                    ras_count <= ras_count + {{RAS_IDX_W{1'b0}}, 1'b1};
            end else if (update_taken && update_is_return &&
                         (ras_count != {(RAS_IDX_W+1){1'b0}})) begin
                ras_sp <= ras_sp - {{(RAS_IDX_W-1){1'b0}}, 1'b1};
                ras_count <= ras_count - {{RAS_IDX_W{1'b0}}, 1'b1};
            end
        end
    end
end

endmodule
