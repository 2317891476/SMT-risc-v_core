`timescale 1ns/1ns
// =============================================================================
// Module : freelist
// Description:
//   Per-thread physical register free FIFO with dual allocate, dual commit free,
//   ROB-walk recovery fallback, and precise branch checkpoints.
// =============================================================================
`include "define.v"

module freelist #(
    parameter PHYS_REG_W    = 6,
    parameter NUM_FREE      = 32,
    parameter FL_DEPTH      = 64,
    parameter FL_IDX_W      = 6,
    parameter BR_CKPT_DEPTH = 32,
    parameter BR_CKPT_IDX_W = 5,
    parameter NUM_THREAD    = 2
)(
    input  wire        clk,
    input  wire        rstn,

    input  wire [0:0]  tid,
    input  wire        alloc0_req,
    input  wire        alloc1_after_alloc0,
    output wire [PHYS_REG_W-1:0] alloc0_prd,
    input  wire        alloc1_req,
    output wire [PHYS_REG_W-1:0] alloc1_prd,
    output wire        can_alloc_1,
    output wire        can_alloc_2,

    input  wire        free0_valid,
    input  wire [PHYS_REG_W-1:0] free0_prd,
    input  wire [0:0]  free0_tid,
    input  wire        free1_valid,
    input  wire [PHYS_REG_W-1:0] free1_prd,
    input  wire [0:0]  free1_tid,

    input  wire        recover_push_valid,
    input  wire [PHYS_REG_W-1:0] recover_push_prd,
    input  wire [0:0]  recover_push_tid,

    input  wire        branch_ckpt_capture0_valid,
    input  wire [0:0]  branch_ckpt_capture0_tid,
    input  wire [`METADATA_ORDER_ID_W-1:0] branch_ckpt_capture0_order_id,
    input  wire [1:0]  branch_ckpt_capture0_alloc_count,
    input  wire        branch_ckpt_capture1_valid,
    input  wire [0:0]  branch_ckpt_capture1_tid,
    input  wire [`METADATA_ORDER_ID_W-1:0] branch_ckpt_capture1_order_id,
    input  wire [1:0]  branch_ckpt_capture1_alloc_count,
    input  wire        branch_ckpt_restore,
    input  wire [0:0]  branch_ckpt_restore_tid,
    input  wire [`METADATA_ORDER_ID_W-1:0] branch_ckpt_restore_order_id,
    output reg         branch_ckpt_restore_hit,
    input  wire        branch_ckpt_drop0_valid,
    input  wire [0:0]  branch_ckpt_drop0_tid,
    input  wire [`METADATA_ORDER_ID_W-1:0] branch_ckpt_drop0_order_id,
    input  wire        branch_ckpt_drop1_valid,
    input  wire [0:0]  branch_ckpt_drop1_tid,
    input  wire [`METADATA_ORDER_ID_W-1:0] branch_ckpt_drop1_order_id,

    input  wire        rebuild_valid,
    input  wire [0:0]  rebuild_tid,
    input  wire [FL_DEPTH-1:0] rebuild_mapped_mask,

    input  wire        reset_list,
    input  wire [0:0]  reset_tid
);

    reg [PHYS_REG_W-1:0] fl_mem  [0:NUM_THREAD-1][0:FL_DEPTH-1];
    reg [FL_IDX_W:0]     fl_head [0:NUM_THREAD-1];
    reg [FL_IDX_W:0]     fl_tail [0:NUM_THREAD-1];

    reg                         ckpt_valid [0:NUM_THREAD-1][0:BR_CKPT_DEPTH-1];
    reg [`METADATA_ORDER_ID_W-1:0] ckpt_order_id [0:NUM_THREAD-1][0:BR_CKPT_DEPTH-1];
    reg [PHYS_REG_W-1:0]        ckpt_mem [0:NUM_THREAD-1][0:BR_CKPT_DEPTH-1][0:FL_DEPTH-1];
    reg [FL_IDX_W:0]            ckpt_head [0:NUM_THREAD-1][0:BR_CKPT_DEPTH-1];
    reg [FL_IDX_W:0]            ckpt_tail [0:NUM_THREAD-1][0:BR_CKPT_DEPTH-1];
    reg [BR_CKPT_IDX_W-1:0]     branch_ckpt_restore_slot;

    wire [FL_IDX_W:0] count [0:NUM_THREAD-1];
    genvar gi;
    generate
        for (gi = 0; gi < NUM_THREAD; gi = gi + 1) begin : gen_count
            assign count[gi] = fl_tail[gi] - fl_head[gi];
        end
    endgenerate

    wire [FL_IDX_W-1:0] head0_idx = fl_head[tid][FL_IDX_W-1:0];
    wire [FL_IDX_W-1:0] head1_idx = head0_idx + 1'b1;
    wire [1:0]          alloc_count = {1'b0, alloc0_req} + {1'b0, alloc1_req};

    assign alloc0_prd = fl_mem[tid][head0_idx];
    assign alloc1_prd = fl_mem[tid][alloc1_after_alloc0 ? head1_idx : head0_idx];
    assign can_alloc_1 = (count[tid] >= 1);
    assign can_alloc_2 = (count[tid] >= 2);

    integer find_idx;
    always @(*) begin
        branch_ckpt_restore_hit  = 1'b0;
        branch_ckpt_restore_slot = {BR_CKPT_IDX_W{1'b0}};
        if (branch_ckpt_restore) begin
            for (find_idx = 0; find_idx < BR_CKPT_DEPTH; find_idx = find_idx + 1) begin
                if (ckpt_valid[branch_ckpt_restore_tid][find_idx] &&
                    (ckpt_order_id[branch_ckpt_restore_tid][find_idx] == branch_ckpt_restore_order_id)) begin
                    branch_ckpt_restore_hit  = 1'b1;
                    branch_ckpt_restore_slot = find_idx[BR_CKPT_IDX_W-1:0];
                end
            end
        end
    end

    integer t, r, c, cap0_slot, cap1_slot, phys_idx, rebuild_tail;
    reg [FL_IDX_W:0] free_tail_after_t0;
    reg [FL_IDX_W:0] free_tail_after_t1;
    reg [FL_IDX_W:0] cap_head_value;
    reg [FL_IDX_W:0] cap_tail_value;

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            for (t = 0; t < NUM_THREAD; t = t + 1) begin
                fl_head[t] <= {(FL_IDX_W+1){1'b0}};
                fl_tail[t] <= NUM_FREE[FL_IDX_W:0];
                for (r = 0; r < FL_DEPTH; r = r + 1)
                    fl_mem[t][r] <= (r < NUM_FREE) ? (32 + r) : {PHYS_REG_W{1'b0}};
                for (c = 0; c < BR_CKPT_DEPTH; c = c + 1) begin
                    ckpt_valid[t][c] <= 1'b0;
                    ckpt_order_id[t][c] <= {`METADATA_ORDER_ID_W{1'b0}};
                    ckpt_head[t][c] <= {(FL_IDX_W+1){1'b0}};
                    ckpt_tail[t][c] <= NUM_FREE[FL_IDX_W:0];
                    for (r = 0; r < FL_DEPTH; r = r + 1)
                        ckpt_mem[t][c][r] <= (r < NUM_FREE) ? (32 + r) : {PHYS_REG_W{1'b0}};
                end
            end
        end else begin
            if (reset_list) begin
                fl_head[reset_tid] <= {(FL_IDX_W+1){1'b0}};
                fl_tail[reset_tid] <= NUM_FREE[FL_IDX_W:0];
                for (r = 0; r < FL_DEPTH; r = r + 1)
                    fl_mem[reset_tid][r] <= (r < NUM_FREE) ? (32 + r) : {PHYS_REG_W{1'b0}};
                for (c = 0; c < BR_CKPT_DEPTH; c = c + 1)
                    ckpt_valid[reset_tid][c] <= 1'b0;
            end else if (rebuild_valid) begin
                fl_head[rebuild_tid] <= {(FL_IDX_W+1){1'b0}};
                rebuild_tail = 0;
                for (r = 0; r < FL_DEPTH; r = r + 1)
                    fl_mem[rebuild_tid][r] <= {PHYS_REG_W{1'b0}};
                for (phys_idx = 1; phys_idx < FL_DEPTH; phys_idx = phys_idx + 1) begin
                    if (!rebuild_mapped_mask[phys_idx] && rebuild_tail < FL_DEPTH) begin
                        fl_mem[rebuild_tid][rebuild_tail] <= phys_idx[PHYS_REG_W-1:0];
                        rebuild_tail = rebuild_tail + 1;
                    end
                end
                fl_tail[rebuild_tid] <= rebuild_tail[FL_IDX_W:0];
                for (c = 0; c < BR_CKPT_DEPTH; c = c + 1)
                    ckpt_valid[rebuild_tid][c] <= 1'b0;
            end else if (branch_ckpt_restore && branch_ckpt_restore_hit) begin
                fl_head[branch_ckpt_restore_tid] <= ckpt_head[branch_ckpt_restore_tid][branch_ckpt_restore_slot];
                fl_tail[branch_ckpt_restore_tid] <= ckpt_tail[branch_ckpt_restore_tid][branch_ckpt_restore_slot];
                for (r = 0; r < FL_DEPTH; r = r + 1)
                    fl_mem[branch_ckpt_restore_tid][r] <= ckpt_mem[branch_ckpt_restore_tid][branch_ckpt_restore_slot][r];
                for (c = 0; c < BR_CKPT_DEPTH; c = c + 1) begin
                    if (ckpt_valid[branch_ckpt_restore_tid][c] &&
                        (ckpt_order_id[branch_ckpt_restore_tid][c] >= branch_ckpt_restore_order_id))
                        ckpt_valid[branch_ckpt_restore_tid][c] <= 1'b0;
                end
            end else begin
                free_tail_after_t0 = fl_tail[0];
                free_tail_after_t1 = fl_tail[1];

                if (alloc_count != 2'd0)
                    fl_head[tid] <= fl_head[tid] + alloc_count;

                if (free0_valid && free0_prd != {PHYS_REG_W{1'b0}}) begin
                    fl_mem[free0_tid][fl_tail[free0_tid][FL_IDX_W-1:0]] <= free0_prd;
                    fl_tail[free0_tid] <= fl_tail[free0_tid] + 1'b1;
                    if (free0_tid == 1'b0)
                        free_tail_after_t0 = fl_tail[free0_tid] + 1'b1;
                    else
                        free_tail_after_t1 = fl_tail[free0_tid] + 1'b1;
                end
                if (free1_valid && free1_prd != {PHYS_REG_W{1'b0}}) begin
                    if (free0_valid && free0_prd != {PHYS_REG_W{1'b0}} && free0_tid == free1_tid) begin
                        fl_mem[free1_tid][fl_tail[free1_tid][FL_IDX_W-1:0] + 1'b1] <= free1_prd;
                        fl_tail[free1_tid] <= fl_tail[free1_tid] + 2'd2;
                        if (free1_tid == 1'b0)
                            free_tail_after_t0 = fl_tail[free1_tid] + 2'd2;
                        else
                            free_tail_after_t1 = fl_tail[free1_tid] + 2'd2;
                    end else begin
                        fl_mem[free1_tid][fl_tail[free1_tid][FL_IDX_W-1:0]] <= free1_prd;
                        fl_tail[free1_tid] <= fl_tail[free1_tid] + 1'b1;
                        if (free1_tid == 1'b0)
                            free_tail_after_t0 = fl_tail[free1_tid] + 1'b1;
                        else
                            free_tail_after_t1 = fl_tail[free1_tid] + 1'b1;
                    end
                end

                if (recover_push_valid && recover_push_prd != {PHYS_REG_W{1'b0}}) begin
                    fl_mem[recover_push_tid][fl_tail[recover_push_tid][FL_IDX_W-1:0]] <= recover_push_prd;
                    fl_tail[recover_push_tid] <= fl_tail[recover_push_tid] + 1'b1;
                end

                // Checkpoint freelists are immutable after capture.  This
                // keeps the freelist image in exact lockstep with the immutable
                // RMT image and avoids restoring a PRF as free while the RMT
                // snapshot still names it.  Commit frees after the checkpoint
                // remain available on the live path; a later mispredict may
                // conservatively lose those frees until a future full reset.

                if (branch_ckpt_drop0_valid) begin
                    for (c = 0; c < BR_CKPT_DEPTH; c = c + 1) begin
                        if (ckpt_valid[branch_ckpt_drop0_tid][c] &&
                            (ckpt_order_id[branch_ckpt_drop0_tid][c] <= branch_ckpt_drop0_order_id))
                            ckpt_valid[branch_ckpt_drop0_tid][c] <= 1'b0;
                    end
                end
                if (branch_ckpt_drop1_valid) begin
                    for (c = 0; c < BR_CKPT_DEPTH; c = c + 1) begin
                        if (ckpt_valid[branch_ckpt_drop1_tid][c] &&
                            (ckpt_order_id[branch_ckpt_drop1_tid][c] <= branch_ckpt_drop1_order_id))
                            ckpt_valid[branch_ckpt_drop1_tid][c] <= 1'b0;
                    end
                end

                cap0_slot = -1;
                if (branch_ckpt_capture0_valid) begin
                    for (c = 0; c < BR_CKPT_DEPTH; c = c + 1) begin
                        if (!ckpt_valid[branch_ckpt_capture0_tid][c] && cap0_slot < 0)
                            cap0_slot = c;
                    end
                    if (cap0_slot >= 0) begin
                        ckpt_valid[branch_ckpt_capture0_tid][cap0_slot] <= 1'b1;
                        ckpt_order_id[branch_ckpt_capture0_tid][cap0_slot] <= branch_ckpt_capture0_order_id;
                        cap_head_value = fl_head[branch_ckpt_capture0_tid] + branch_ckpt_capture0_alloc_count;
                        cap_tail_value = fl_tail[branch_ckpt_capture0_tid];
                        ckpt_head[branch_ckpt_capture0_tid][cap0_slot] <= cap_head_value;
                        ckpt_tail[branch_ckpt_capture0_tid][cap0_slot] <= cap_tail_value;
                        for (r = 0; r < FL_DEPTH; r = r + 1)
                            ckpt_mem[branch_ckpt_capture0_tid][cap0_slot][r] <= fl_mem[branch_ckpt_capture0_tid][r];
                    end
                end

                cap1_slot = -1;
                if (branch_ckpt_capture1_valid) begin
                    for (c = 0; c < BR_CKPT_DEPTH; c = c + 1) begin
                        if (!ckpt_valid[branch_ckpt_capture1_tid][c] &&
                            !((branch_ckpt_capture0_valid && branch_ckpt_capture0_tid == branch_ckpt_capture1_tid) && (cap0_slot == c)) &&
                            cap1_slot < 0)
                            cap1_slot = c;
                    end
                    if (cap1_slot >= 0) begin
                        ckpt_valid[branch_ckpt_capture1_tid][cap1_slot] <= 1'b1;
                        ckpt_order_id[branch_ckpt_capture1_tid][cap1_slot] <= branch_ckpt_capture1_order_id;
                        cap_head_value = fl_head[branch_ckpt_capture1_tid] + branch_ckpt_capture1_alloc_count;
                        cap_tail_value = fl_tail[branch_ckpt_capture1_tid];
                        ckpt_head[branch_ckpt_capture1_tid][cap1_slot] <= cap_head_value;
                        ckpt_tail[branch_ckpt_capture1_tid][cap1_slot] <= cap_tail_value;
                        for (r = 0; r < FL_DEPTH; r = r + 1)
                            ckpt_mem[branch_ckpt_capture1_tid][cap1_slot][r] <= fl_mem[branch_ckpt_capture1_tid][r];
                    end
                end
            end
        end
    end

    // synthesis translate_off
    always @(posedge clk) begin
        if (rstn) begin
            if (alloc0_req && !can_alloc_1)
                $display("ERROR: freelist T%0d alloc0 underflow at %0t", tid, $time);
            if (alloc0_req && alloc1_req && !can_alloc_2)
                $display("ERROR: freelist T%0d alloc1 underflow at %0t", tid, $time);
        end
    end
    // synthesis translate_on

endmodule
