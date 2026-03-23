// =============================================================================
// Module : rocc_ai_accelerator
// Description: RoCC-style AI Co-Processor with three functional sub-engines:
//   1) GEMM Engine  — 8×8 INT8 output-stationary systolic array
//   2) Vector Unit  — 128-bit SIMD (4× INT32) for activation functions
//   3) Context Compressor — KV-Cache INT4 quantization + Top-K selection
//
//   Instruction encoding via RISC-V custom-0 (opcode 0x0B):
//     funct7[6:0] selects the operation:
//       0 = GEMM.START    : Start matrix multiply (base addrs in rs1, rs2)
//       1 = VEC.OP        : Vector operation (funct3 selects sub-op)
//       2 = CTX.COMPRESS  : KV-Cache compress (rs1=src, rs2=dst, rd=count)
//       3 = SCRATCH.LOAD  : Load data into scratchpad
//       4 = SCRATCH.STORE : Store data from scratchpad
//       5 = STATUS.READ   : Read accelerator status into rd
//
//   VEC.OP funct3 sub-operations:
//       000 = VADD    (vector add)
//       001 = VMUL    (vector element-wise multiply)
//       010 = VRELU   (vector ReLU)
//       011 = VSCALE  (vector scale / shift for quantization)
//       100 = VREDUCE (vector reduction sum)
// =============================================================================
module rocc_ai_accelerator #(
    parameter SA_SIZE     = 8,        // Systolic array dimension (8×8)
    parameter VEC_WIDTH   = 128,      // Vector unit width in bits
    parameter SCRATCH_KB  = 4,        // Scratchpad size in KB (reduced for FPGA)
    parameter TAG_W       = 5
)(
    input  wire               clk,
    input  wire               rstn,

    // ─── RoCC Command Interface (from Scoreboard) ───────────────
    input  wire               cmd_valid,
    output wire               cmd_ready,
    input  wire [6:0]         cmd_funct7,
    input  wire [2:0]         cmd_funct3,
    input  wire [4:0]         cmd_rd,
    input  wire [31:0]        cmd_rs1_data,
    input  wire [31:0]        cmd_rs2_data,
    input  wire [TAG_W-1:0]   cmd_tag,
    input  wire [0:0]         cmd_tid,

    // ─── RoCC Response Interface (to WB) ────────────────────────
    output reg                resp_valid,
    input  wire               resp_ready,
    output reg  [4:0]         resp_rd,
    output reg  [31:0]        resp_data,
    output reg  [TAG_W-1:0]   resp_tag,
    output reg  [0:0]         resp_tid,

    // ─── Memory Interface (DMA to main memory) ──────────────────
    output reg                mem_req_valid,
    input  wire               mem_req_ready,
    output reg  [31:0]        mem_req_addr,
    output reg  [31:0]        mem_req_wdata,
    output reg                mem_req_wen,
    input  wire               mem_resp_valid,
    input  wire [31:0]        mem_resp_rdata,

    // ─── Status ─────────────────────────────────────────────────
    output wire               accel_busy,
    output wire               accel_interrupt
);

// ─── State Machine ──────────────────────────────────────────────────────────
localparam ST_IDLE      = 4'd0;
localparam ST_GEMM_LOAD = 4'd1;
localparam ST_GEMM_COMP = 4'd2;
localparam ST_GEMM_STORE= 4'd3;
localparam ST_VEC_EXEC  = 4'd4;
localparam ST_CTX_LOAD  = 4'd5;
localparam ST_CTX_COMP  = 4'd6;
localparam ST_CTX_STORE = 4'd7;
localparam ST_SCRATCH_LD= 4'd8;
localparam ST_SCRATCH_ST= 4'd9;
localparam ST_RESP      = 4'd10;

reg [3:0]  state;
reg [6:0]  op_funct7;
reg [2:0]  op_funct3;
reg [4:0]  op_rd;
reg [31:0] op_rs1, op_rs2;
reg [TAG_W-1:0] op_tag;
reg [0:0]  op_tid;

assign cmd_ready      = (state == ST_IDLE);
assign accel_busy     = (state != ST_IDLE);
assign accel_interrupt = 1'b0; // TODO: interrupt on completion

// ─── Scratchpad Memory ──────────────────────────────────────────────────────
localparam SCRATCH_WORDS = SCRATCH_KB * 256; // (KB * 1024 / 4)
reg [31:0] scratchpad [0:SCRATCH_WORDS-1];

// ─── GEMM Accumulators (8×8 INT32 output) ───────────────────────────────────
reg signed [31:0] gemm_acc [0:SA_SIZE-1][0:SA_SIZE-1];

// ─── Vector Registers (4 × 32-bit elements) ────────────────────────────────
reg [31:0] vec_a [0:3];
reg [31:0] vec_b [0:3];
reg [31:0] vec_r [0:3];

// ─── Working registers ─────────────────────────────────────────────────────
reg [31:0] dma_addr;
reg [15:0] dma_cnt;
reg [15:0] dma_total;
reg [3:0]  gemm_row, gemm_col, gemm_k;
reg [31:0] result_reg;

integer gi, gj, gk;

// ─── Main FSM ───────────────────────────────────────────────────────────────
always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        state      <= ST_IDLE;
        resp_valid <= 1'b0;
        resp_rd    <= 5'd0;
        resp_data  <= 32'd0;
        resp_tag   <= {TAG_W{1'b0}};
        resp_tid   <= 1'b0;
        mem_req_valid <= 1'b0;
        mem_req_addr  <= 32'd0;
        mem_req_wdata <= 32'd0;
        mem_req_wen   <= 1'b0;
        dma_addr      <= 32'd0;
        dma_cnt       <= 16'd0;
        dma_total     <= 16'd0;
        gemm_row      <= 4'd0;
        gemm_col      <= 4'd0;
        gemm_k        <= 4'd0;
        result_reg    <= 32'd0;
        op_funct7     <= 7'd0;
        op_funct3     <= 3'd0;
        op_rd         <= 5'd0;
        op_rs1        <= 32'd0;
        op_rs2        <= 32'd0;
        op_tag        <= {TAG_W{1'b0}};
        op_tid        <= 1'b0;
        for (gi = 0; gi < SA_SIZE; gi = gi + 1)
            for (gj = 0; gj < SA_SIZE; gj = gj + 1)
                gemm_acc[gi][gj] <= 32'd0;
    end
    else begin
        resp_valid    <= 1'b0;
        mem_req_valid <= 1'b0;

        case (state)
            ST_IDLE: begin
                if (cmd_valid) begin
                    op_funct7 <= cmd_funct7;
                    op_funct3 <= cmd_funct3;
                    op_rd     <= cmd_rd;
                    op_rs1    <= cmd_rs1_data;
                    op_rs2    <= cmd_rs2_data;
                    op_tag    <= cmd_tag;
                    op_tid    <= cmd_tid;

                    case (cmd_funct7)
                        7'd0: begin // GEMM.START
                            // Initialize accumulator to zero
                            for (gi = 0; gi < SA_SIZE; gi = gi + 1)
                                for (gj = 0; gj < SA_SIZE; gj = gj + 1)
                                    gemm_acc[gi][gj] <= 32'd0;
                            dma_addr  <= cmd_rs1_data; // matrix A base
                            dma_cnt   <= 16'd0;
                            dma_total <= SA_SIZE * SA_SIZE; // load A
                            state     <= ST_GEMM_LOAD;
                        end

                        7'd1: begin // VEC.OP
                            // Load vector operands from rs1/rs2 as packed INT8×4
                            vec_a[0] <= cmd_rs1_data[7:0];
                            vec_a[1] <= cmd_rs1_data[15:8];
                            vec_a[2] <= cmd_rs1_data[23:16];
                            vec_a[3] <= cmd_rs1_data[31:24];
                            vec_b[0] <= cmd_rs2_data[7:0];
                            vec_b[1] <= cmd_rs2_data[15:8];
                            vec_b[2] <= cmd_rs2_data[23:16];
                            vec_b[3] <= cmd_rs2_data[31:24];
                            state    <= ST_VEC_EXEC;
                        end

                        7'd5: begin // STATUS.READ
                            result_reg <= {31'd0, accel_busy};
                            state      <= ST_RESP;
                        end

                        default: begin
                            // Unimplemented — return 0
                            result_reg <= 32'd0;
                            state      <= ST_RESP;
                        end
                    endcase
                end
            end

            // ── GEMM: simplified DMA load → compute → respond ───
            ST_GEMM_LOAD: begin
                // Simplified: compute immediately (actual DMA would stream from memory)
                // For now: compute 8×8 dot products using accumulator
                for (gi = 0; gi < SA_SIZE; gi = gi + 1)
                    for (gj = 0; gj < SA_SIZE; gj = gj + 1)
                        gemm_acc[gi][gj] <= gemm_acc[gi][gj]; // placeholder
                state <= ST_GEMM_COMP;
            end

            ST_GEMM_COMP: begin
                // Simplified systolic computation cycle
                // In a full implementation this would iterate over K dimension
                result_reg <= gemm_acc[0][0]; // return top-left element
                state      <= ST_RESP;
            end

            // ── Vector execution ────────────────────────────────
            ST_VEC_EXEC: begin
                case (op_funct3)
                    3'b000: begin // VADD
                        vec_r[0] <= vec_a[0] + vec_b[0];
                        vec_r[1] <= vec_a[1] + vec_b[1];
                        vec_r[2] <= vec_a[2] + vec_b[2];
                        vec_r[3] <= vec_a[3] + vec_b[3];
                    end
                    3'b001: begin // VMUL
                        vec_r[0] <= vec_a[0] * vec_b[0];
                        vec_r[1] <= vec_a[1] * vec_b[1];
                        vec_r[2] <= vec_a[2] * vec_b[2];
                        vec_r[3] <= vec_a[3] * vec_b[3];
                    end
                    3'b010: begin // VRELU
                        vec_r[0] <= ($signed(vec_a[0]) > 0) ? vec_a[0] : 32'd0;
                        vec_r[1] <= ($signed(vec_a[1]) > 0) ? vec_a[1] : 32'd0;
                        vec_r[2] <= ($signed(vec_a[2]) > 0) ? vec_a[2] : 32'd0;
                        vec_r[3] <= ($signed(vec_a[3]) > 0) ? vec_a[3] : 32'd0;
                    end
                    3'b100: begin // VREDUCE (sum)
                        vec_r[0] <= vec_a[0] + vec_a[1] + vec_a[2] + vec_a[3];
                        vec_r[1] <= 32'd0;
                        vec_r[2] <= 32'd0;
                        vec_r[3] <= 32'd0;
                    end
                    default: begin
                        vec_r[0] <= 32'd0; vec_r[1] <= 32'd0;
                        vec_r[2] <= 32'd0; vec_r[3] <= 32'd0;
                    end
                endcase
                // Pack result back into 32-bit
                result_reg <= {vec_r[3][7:0], vec_r[2][7:0], vec_r[1][7:0], vec_r[0][7:0]};
                state      <= ST_RESP;
            end

            // ── Response ────────────────────────────────────────
            ST_RESP: begin
                if (resp_ready || !resp_valid) begin
                    resp_valid <= 1'b1;
                    resp_rd    <= op_rd;
                    resp_data  <= result_reg;
                    resp_tag   <= op_tag;
                    resp_tid   <= op_tid;
                    state      <= ST_IDLE;
                end
            end

            default: state <= ST_IDLE;
        endcase
    end
end

endmodule
