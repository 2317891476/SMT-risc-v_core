`timescale 1ns/1ns
// =============================================================================
// Module : freelist
// Description: Physical register free‑list, one circular FIFO per thread.
//   Manages phys_reg 32‥47 for each thread (arch regs 0‥31 are pre‑allocated).
//   Supports:
//   - Dual allocate (2 phys regs/cycle for dual-dispatch)
//   - Dual free (2 phys regs/cycle at commit)
//   - Single-cycle ROB walk push‑back (free recovered prd_new to freelist)
//   - Bulk reset (trap flush: re-initialize freelist to phys 32..47)
//
//   Empty condition: alloc blocked → stalls rename.
// =============================================================================
`include "define.v"

module freelist #(
    parameter PHYS_REG_W   = 6,
    parameter NUM_FREE     = 16,   // initial free count: phys regs 32..47 per thread
    parameter FL_DEPTH     = 64,   // FIFO depth (power-of-2 for mod arithmetic; max ~47 entries used)
    parameter FL_IDX_W     = 6,    // clog2(FL_DEPTH)
    parameter NUM_THREAD   = 2
)(
    input  wire        clk,
    input  wire        rstn,

    // ─── Allocate (rename stage → pop from head) ─────────────────
    input  wire [0:0]  tid,           // thread requesting alloc
    input  wire        alloc0_req,
    output wire [PHYS_REG_W-1:0] alloc0_prd,
    input  wire        alloc1_req,
    output wire [PHYS_REG_W-1:0] alloc1_prd,
    output wire        can_alloc_1,   // at least 1 free reg available
    output wire        can_alloc_2,   // at least 2 free regs available

    // ─── Free (commit stage → push to tail) ──────────────────────
    input  wire        free0_valid,
    input  wire [PHYS_REG_W-1:0] free0_prd,
    input  wire [0:0]  free0_tid,
    input  wire        free1_valid,
    input  wire [PHYS_REG_W-1:0] free1_prd,
    input  wire [0:0]  free1_tid,

    // ─── ROB walk recovery (push speculative prd_new back) ───────
    input  wire        recover_push_valid,
    input  wire [PHYS_REG_W-1:0] recover_push_prd,
    input  wire [0:0]  recover_push_tid,

    // ─── Bulk reset (trap flush) ─────────────────────────────────
    input  wire        reset_list,
    input  wire [0:0]  reset_tid
);

    // ═══ Storage: circular FIFO per thread ═══
    // Each FIFO holds phys reg IDs
    reg [PHYS_REG_W-1:0] fl_mem [0:NUM_THREAD-1][0:FL_DEPTH-1];
    reg [FL_IDX_W:0]     fl_head [0:NUM_THREAD-1]; // extra bit for full/empty
    reg [FL_IDX_W:0]     fl_tail [0:NUM_THREAD-1];

    // ═══ Count computation ═══
    wire [FL_IDX_W:0] count [0:NUM_THREAD-1];
    genvar gi;
    generate
        for (gi = 0; gi < NUM_THREAD; gi = gi + 1) begin : gen_count
            assign count[gi] = fl_tail[gi] - fl_head[gi];
        end
    endgenerate

    // ═══ Alloc read ports (combinational) ═══
    wire [FL_IDX_W-1:0] head0_idx = fl_head[tid][FL_IDX_W-1:0];
    wire [FL_IDX_W-1:0] head1_idx = head0_idx + 1'b1;  // wraps naturally

    assign alloc0_prd = fl_mem[tid][head0_idx];
    assign alloc1_prd = fl_mem[tid][head1_idx];

    assign can_alloc_1 = (count[tid] >= 1);
    assign can_alloc_2 = (count[tid] >= 2);

    // ═══ Sequential Alloc / Free ═══
    integer t, r;
    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            // Initialize: phys regs 32..47 in FIFO (first 16 entries)
            for (t = 0; t < NUM_THREAD; t = t + 1) begin
                fl_head[t] <= {(FL_IDX_W+1){1'b0}};
                fl_tail[t] <= NUM_FREE[FL_IDX_W:0];
                for (r = 0; r < FL_DEPTH; r = r + 1)
                    fl_mem[t][r] <= (r < NUM_FREE) ? (32 + r) : {PHYS_REG_W{1'b0}};
            end
        end
        else begin
            // ── Bulk reset (trap flush) ──
            if (reset_list) begin
                fl_head[reset_tid] <= {(FL_IDX_W+1){1'b0}};
                fl_tail[reset_tid] <= NUM_FREE[FL_IDX_W:0];
                for (r = 0; r < FL_DEPTH; r = r + 1)
                    fl_mem[reset_tid][r] <= (r < NUM_FREE) ? (32 + r) : {PHYS_REG_W{1'b0}};
            end
            else begin
                // ── Allocate: advance head ──
                if (alloc0_req && alloc1_req) begin
                    fl_head[tid] <= fl_head[tid] + 2;
                end
                else if (alloc0_req) begin
                    fl_head[tid] <= fl_head[tid] + 1;
                end

                // ── Free at commit: push to tail ──
                // free0 and free1 may target different threads
                // Allow any phys reg except P0 (x0 identity) to be freed
                if (free0_valid && free0_prd != {PHYS_REG_W{1'b0}}) begin
                    fl_mem[free0_tid][fl_tail[free0_tid][FL_IDX_W-1:0]] <= free0_prd;
                    fl_tail[free0_tid] <= fl_tail[free0_tid] + 1;
                end
                if (free1_valid && free1_prd != {PHYS_REG_W{1'b0}}) begin
                    // If free0 and free1 are same thread, must account for free0's write
                    if (free0_valid && free0_prd != {PHYS_REG_W{1'b0}} && free0_tid == free1_tid) begin
                        fl_mem[free1_tid][fl_tail[free1_tid][FL_IDX_W-1:0] + 1'b1] <= free1_prd;
                        fl_tail[free1_tid] <= fl_tail[free1_tid] + 2;
                    end
                    else begin
                        fl_mem[free1_tid][fl_tail[free1_tid][FL_IDX_W-1:0]] <= free1_prd;
                        fl_tail[free1_tid] <= fl_tail[free1_tid] + 1;
                    end
                end

                // ── Recovery push-back (ROB walk) ──
                if (recover_push_valid && recover_push_prd != {PHYS_REG_W{1'b0}}) begin
                    // During recovery, alloc is stalled (rename blocked)
                    // So we just push to tail
                    fl_mem[recover_push_tid][fl_tail[recover_push_tid][FL_IDX_W-1:0]] <= recover_push_prd;
                    fl_tail[recover_push_tid] <= fl_tail[recover_push_tid] + 1;
                end
            end
        end
    end

    // ═══ Assertions (simulation only) ═══
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
