// =============================================================================
// Module : fetch_buffer
// Description: Dual-entry instruction fetch buffer (FIFO) between IF and Decode.
//   Buffers up to 2 fetched instructions per thread, enabling dual-issue decode.
//   Supports per-thread flush and backpressure (stall) from the decode stage.
//
//   Operation:
//   - Each cycle, IF stage can push 1 instruction (from the selected thread).
//   - The decode stage can pop up to 2 instructions if they share the same thread
//     and both slots are valid.
//   - On flush[tid], all entries belonging to that thread are invalidated.
//
// Port summary:
//   push_*    — from IF stage
//   pop_*     — to dual decode stage
//   flush     — per-thread flush
//   stall_out — backpressure to IF
// =============================================================================
module fetch_buffer #(
    parameter DEPTH = 4       // Total FIFO depth (should be >= 2 * num_threads)
)(
    input  wire        clk,
    input  wire        rstn,

    // ─── Flush (per-thread) ──────────────────────────────────────
    input  wire [1:0]  flush,          // flush[t] = invalidate thread t entries

    // ─── Push port (from IF stage, 1 instr/cycle) ────────────────
    input  wire        push_valid,     // IF has a valid instruction
    input  wire [31:0] push_inst,      // instruction word
    input  wire [31:0] push_pc,        // instruction PC
    input  wire [0:0]  push_tid,       // thread ID
    input  wire        push_pred_taken,
    input  wire [31:0] push_pred_target,
    input  wire        push_pred_hit,
    input  wire [1:0]  push_pred_type,
    output wire        push_ready,     // buffer can accept (not full for this thread)

    // ─── Pop port 0 (to Decoder 0, oldest instruction) ──────────
    output wire        pop0_valid,     // slot 0 has a valid instruction
    output wire [31:0] pop0_inst,      // instruction word
    output wire [31:0] pop0_pc,        // instruction PC
    output wire [0:0]  pop0_tid,       // thread ID
    output wire        pop0_pred_taken,
    output wire [31:0] pop0_pred_target,
    output wire        pop0_pred_hit,
    output wire [1:0]  pop0_pred_type,

    // ─── Pop port 1 (to Decoder 1, second-oldest, same thread) ──
    output wire        pop1_valid,     // slot 1 valid AND same thread as slot 0
    output wire [31:0] pop1_inst,
    output wire [31:0] pop1_pc,
    output wire [0:0]  pop1_tid,
    output wire        pop1_pred_taken,
    output wire [31:0] pop1_pred_target,
    output wire        pop1_pred_hit,
    output wire [1:0]  pop1_pred_type,

    // ─── Consume (from decode stage) ─────────────────────────────
    input  wire        consume_0,      // decode consumed slot 0
    input  wire        consume_1       // decode consumed slot 1 (only if pop1_valid)
);

localparam IDX_W = $clog2(DEPTH);

// FIFO storage
reg [31:0] buf_inst [0:DEPTH-1];
reg [31:0] buf_pc   [0:DEPTH-1];
reg [0:0]  buf_tid  [0:DEPTH-1];
reg        buf_pred_taken [0:DEPTH-1];
reg [31:0] buf_pred_target[0:DEPTH-1];
reg        buf_pred_hit   [0:DEPTH-1];
reg [1:0]  buf_pred_type  [0:DEPTH-1];
reg        buf_valid[0:DEPTH-1];

// FIFO pointers
reg [IDX_W:0] head;   // write pointer (push)
reg [IDX_W:0] tail;   // read pointer  (pop)

wire [IDX_W:0] count;
assign count = head - tail;

// Full / empty
wire fifo_full;
wire fifo_empty;
assign fifo_full  = (count >= DEPTH[IDX_W:0]);
assign fifo_empty = (count == 0);

assign push_ready = !fifo_full;

// Pop outputs — slot 0 is at tail, slot 1 is at tail+1
wire [IDX_W-1:0] tail_idx;
wire [IDX_W-1:0] tail_idx_p1;
assign tail_idx    = tail[IDX_W-1:0];
assign tail_idx_p1 = tail_idx + 1;

assign pop0_valid = !fifo_empty && buf_valid[tail_idx];
assign pop0_inst  = buf_inst[tail_idx];
assign pop0_pc    = buf_pc[tail_idx];
assign pop0_tid   = buf_tid[tail_idx];
assign pop0_pred_taken  = buf_pred_taken[tail_idx];
assign pop0_pred_target = buf_pred_target[tail_idx];
assign pop0_pred_hit    = buf_pred_hit[tail_idx];
assign pop0_pred_type   = buf_pred_type[tail_idx];

// Slot 1 valid only if: count >= 2, same thread, and both valid
wire slot1_exists;
assign slot1_exists = (count >= 2) && buf_valid[tail_idx_p1];
assign pop1_valid = slot1_exists && (buf_tid[tail_idx_p1] == buf_tid[tail_idx]);
assign pop1_inst  = buf_inst[tail_idx_p1];
assign pop1_pc    = buf_pc[tail_idx_p1];
assign pop1_tid   = buf_tid[tail_idx_p1];
assign pop1_pred_taken  = buf_pred_taken[tail_idx_p1];
assign pop1_pred_target = buf_pred_target[tail_idx_p1];
assign pop1_pred_hit    = buf_pred_hit[tail_idx_p1];
assign pop1_pred_type   = buf_pred_type[tail_idx_p1];

integer i;

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        head <= 0;
        tail <= 0;
        for (i = 0; i < DEPTH; i = i + 1) begin
            buf_valid[i] <= 1'b0;
            buf_inst[i]  <= 32'd0;
            buf_pc[i]    <= 32'd0;
            buf_tid[i]   <= 1'b0;
            buf_pred_taken[i]  <= 1'b0;
            buf_pred_target[i] <= 32'd0;
            buf_pred_hit[i]    <= 1'b0;
            buf_pred_type[i]   <= 2'd0;
        end
    end
    else begin
        // ── Flush: invalidate entries of flushed thread(s) ──────
        // Per-thread flush: only invalidate entries belonging to flushed thread(s)
        // Do NOT reset head/tail - other thread's work must be preserved
        if (|flush) begin
            // Selective invalidation: only mark flushed thread's entries as invalid
            for (i = 0; i < DEPTH; i = i + 1) begin
                if (buf_valid[i] && flush[buf_tid[i]]) begin
                    buf_valid[i] <= 1'b0;
                end
            end
            // Note: head/tail are NOT reset - other thread's buffered work is preserved
            // The consume logic will naturally skip invalid entries
        end
        else begin
            // ── Auto-skip invalid entries at tail (post-flush cleanup) ──
            // After flush, tail may point to an invalid entry - skip it to prevent deadlock
            if (!fifo_empty && !buf_valid[tail_idx]) begin
                // Advance tail past invalid (flushed) entries
                tail <= tail + 1;
            end
            // ── Consume (pop) ───────────────────────────────────
            else if (consume_0 && pop0_valid) begin
                buf_valid[tail_idx] <= 1'b0;
                if (consume_1 && pop1_valid) begin
                    // Both consumed
                    tail <= tail + 2;
                    buf_valid[tail_idx_p1] <= 1'b0;
                end
                else begin
                    tail <= tail + 1;
                end
            end

            // ── Push ────────────────────────────────────────────
            if (push_valid && push_ready) begin
                buf_inst[head[IDX_W-1:0]]  <= push_inst;
                buf_pc[head[IDX_W-1:0]]    <= push_pc;
                buf_tid[head[IDX_W-1:0]]   <= push_tid;
                buf_pred_taken[head[IDX_W-1:0]]  <= push_pred_taken;
                buf_pred_target[head[IDX_W-1:0]] <= push_pred_target;
                buf_pred_hit[head[IDX_W-1:0]]    <= push_pred_hit;
                buf_pred_type[head[IDX_W-1:0]]   <= push_pred_type;
                buf_valid[head[IDX_W-1:0]] <= 1'b1;
                head <= head + 1;
            end
        end
    end
end

endmodule
