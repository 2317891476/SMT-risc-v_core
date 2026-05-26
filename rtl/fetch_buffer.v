// =============================================================================
// Module : fetch_buffer
// Description: Dual-entry instruction fetch buffer (FIFO) between IF and Decode.
//   Buffers up to DEPTH fetched instructions, enabling dual-issue decode.
//   Supports flush and backpressure (stall) from the decode stage.
//
//   Operation:
//   - Each cycle, IF stage can push 1 instruction.
//   - The decode stage can pop up to 2 instructions if both slots are valid.
//   - On flush, all entries are invalidated.
// =============================================================================
module fetch_buffer #(
    parameter DEPTH = 4
)(
    input  wire        clk,
    input  wire        rstn,

    // Flush
    input  wire        flush,

    // Push port (from IF stage, 1 instr/cycle)
    input  wire        push_valid,
    input  wire [31:0] push_inst,
    input  wire [31:0] push_pc,
    input  wire        push_pred_taken,
    input  wire [31:0] push_pred_target,
    input  wire        push_fault,
    input  wire [4:0]  push_fault_cause,
    input  wire [31:0] push_fault_tval,
    output wire        push_ready,

    // Pop port 0 (to Decoder 0, oldest instruction)
    output wire        pop0_valid,
    output wire [31:0] pop0_inst,
    output wire [31:0] pop0_pc,
    output wire        pop0_pred_taken,
    output wire [31:0] pop0_pred_target,
    output wire        pop0_fault,
    output wire [4:0]  pop0_fault_cause,
    output wire [31:0] pop0_fault_tval,

    // Pop port 1 (to Decoder 1, second-oldest)
    output wire        pop1_valid,
    output wire [31:0] pop1_inst,
    output wire [31:0] pop1_pc,
    output wire        pop1_pred_taken,
    output wire [31:0] pop1_pred_target,
    output wire        pop1_fault,
    output wire [4:0]  pop1_fault_cause,
    output wire [31:0] pop1_fault_tval,

    // Consume (from decode stage)
    input  wire        consume_0,
    input  wire        consume_1
);

localparam IDX_W = $clog2(DEPTH);

// FIFO storage
reg [31:0] buf_inst [0:DEPTH-1];
reg [31:0] buf_pc   [0:DEPTH-1];
reg        buf_pred_taken [0:DEPTH-1];
reg [31:0] buf_pred_target[0:DEPTH-1];
reg        buf_fault      [0:DEPTH-1];
reg [4:0]  buf_fault_cause[0:DEPTH-1];
reg [31:0] buf_fault_tval [0:DEPTH-1];
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

// Pop outputs
wire [IDX_W-1:0] tail_idx;
wire [IDX_W-1:0] tail_idx_p1;
assign tail_idx    = tail[IDX_W-1:0];
assign tail_idx_p1 = tail_idx + 1;

assign pop0_valid = !fifo_empty && buf_valid[tail_idx];
assign pop0_inst  = buf_inst[tail_idx];
assign pop0_pc    = buf_pc[tail_idx];
assign pop0_pred_taken  = buf_pred_taken[tail_idx];
assign pop0_pred_target = buf_pred_target[tail_idx];
assign pop0_fault       = buf_fault[tail_idx];
assign pop0_fault_cause = buf_fault_cause[tail_idx];
assign pop0_fault_tval  = buf_fault_tval[tail_idx];

// Slot 1 valid only if: count >= 2 and both valid
wire slot1_exists;
assign slot1_exists = (count >= 2) && buf_valid[tail_idx_p1];
assign pop1_valid = slot1_exists;
assign pop1_inst  = buf_inst[tail_idx_p1];
assign pop1_pc    = buf_pc[tail_idx_p1];
assign pop1_pred_taken  = buf_pred_taken[tail_idx_p1];
assign pop1_pred_target = buf_pred_target[tail_idx_p1];
assign pop1_fault       = buf_fault[tail_idx_p1];
assign pop1_fault_cause = buf_fault_cause[tail_idx_p1];
assign pop1_fault_tval  = buf_fault_tval[tail_idx_p1];

integer i;

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        head <= 0;
        tail <= 0;
        for (i = 0; i < DEPTH; i = i + 1) begin
            buf_valid[i] <= 1'b0;
            buf_inst[i]  <= 32'd0;
            buf_pc[i]    <= 32'd0;
            buf_pred_taken[i]  <= 1'b0;
            buf_pred_target[i] <= 32'd0;
            buf_fault[i]       <= 1'b0;
            buf_fault_cause[i] <= 5'd0;
            buf_fault_tval[i]  <= 32'd0;
        end
    end
    else begin
        if (flush) begin
            head <= 0;
            tail <= 0;
            for (i = 0; i < DEPTH; i = i + 1) begin
                buf_valid[i] <= 1'b0;
            end
        end
        else begin
            // Auto-skip invalid entries at tail (post-flush cleanup)
            if (!fifo_empty && !buf_valid[tail_idx]) begin
                tail <= tail + 1;
            end
            // Consume (pop)
            else if (consume_0 && pop0_valid) begin
                buf_valid[tail_idx] <= 1'b0;
                if (consume_1 && pop1_valid) begin
                    tail <= tail + 2;
                    buf_valid[tail_idx_p1] <= 1'b0;
                end
                else begin
                    tail <= tail + 1;
                end
            end

            // Push
            if (push_valid && push_ready) begin
                buf_inst[head[IDX_W-1:0]]  <= push_inst;
                buf_pc[head[IDX_W-1:0]]    <= push_pc;
                buf_pred_taken[head[IDX_W-1:0]]  <= push_pred_taken;
                buf_pred_target[head[IDX_W-1:0]] <= push_pred_target;
                buf_fault[head[IDX_W-1:0]]       <= push_fault;
                buf_fault_cause[head[IDX_W-1:0]] <= push_fault_cause;
                buf_fault_tval[head[IDX_W-1:0]]  <= push_fault_tval;
                buf_valid[head[IDX_W-1:0]] <= 1'b1;
                head <= head + 1;
            end
        end
    end
end

endmodule
