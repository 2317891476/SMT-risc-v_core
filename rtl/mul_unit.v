// =============================================================================
// Module : mul_unit
// Description: 3-cycle pipelined Booth multiplier for RV32M extension.
//   Supports: MUL, MULH, MULHSU, MULHU
//   Uses a 3-stage pipeline to meet Fmax targets on FPGA.
//
//   Stage 1: Compute partial products (operand conditioning)
//   Stage 2: 64-bit multiplication
//   Stage 3: Result selection (low 32 / high 32) and output
// =============================================================================
`include "define.v"

module mul_unit #(
    parameter TAG_W = 5
)(
    input  wire               clk,
    input  wire               rstn,

    // ─── Input (from Issue stage) ───────────────────────────────
    input  wire               in_valid,
    input  wire [TAG_W-1:0]   in_tag,
    input  wire [31:0]        in_op_a,       // rs1 data
    input  wire [31:0]        in_op_b,       // rs2 data
    input  wire [2:0]         in_func3,      // 000=MUL, 001=MULH, 010=MULHSU, 011=MULHU
    input  wire [4:0]         in_rd,
    input  wire               in_regs_write,
    input  wire [2:0]         in_fu,
    input  wire [0:0]         in_tid,
    input  wire [`METADATA_ORDER_ID_W-1:0] in_order_id,

    // ─── Output (to WB) ────────────────────────────────────────
    output wire               out_valid,
    output wire [TAG_W-1:0]   out_tag,
    output wire [31:0]        out_result,
    output wire [4:0]         out_rd,
    output wire               out_regs_write,
    output wire [2:0]         out_fu,
    output wire [0:0]         out_tid,
    output wire [`METADATA_ORDER_ID_W-1:0] out_order_id
);

// ─── Stage 1→2 pipeline registers ──────────────────────────────────────────
reg               s1_valid;
reg [TAG_W-1:0]   s1_tag;
reg [63:0]        s1_prod;       // product computed in stage 1
reg [2:0]         s1_func3;
reg [4:0]         s1_rd;
reg               s1_regs_write;
reg [2:0]         s1_fu;
reg [0:0]         s1_tid;
reg [`METADATA_ORDER_ID_W-1:0] s1_order_id;

// ─── Stage 2→3 pipeline registers ──────────────────────────────────────────
reg               s2_valid;
reg [TAG_W-1:0]   s2_tag;
reg [63:0]        s2_prod;
reg [2:0]         s2_func3;
reg [4:0]         s2_rd;
reg               s2_regs_write;
reg [2:0]         s2_fu;
reg [0:0]         s2_tid;
reg [`METADATA_ORDER_ID_W-1:0] s2_order_id;

// ─── Stage 3 output registers ──────────────────────────────────────────────
reg               s3_valid;
reg [TAG_W-1:0]   s3_tag;
reg [31:0]        s3_result;
reg [4:0]         s3_rd;
reg               s3_regs_write;
reg [2:0]         s3_fu;
reg [0:0]         s3_tid;
reg [`METADATA_ORDER_ID_W-1:0] s3_order_id;

// ─── Stage 1: Multiplication (operand conditioning + multiply) ──────────────
wire signed [32:0] mul_a;
wire signed [32:0] mul_b;
wire signed [65:0] mul_full;

// Extend operands based on func3:
//   MUL/MULH:   signed × signed
//   MULHSU:     signed × unsigned
//   MULHU:      unsigned × unsigned
assign mul_a = (in_func3 == 3'b011) ? {1'b0, in_op_a} : {in_op_a[31], in_op_a};  // MULHU: unsigned
assign mul_b = (in_func3[1])        ? {1'b0, in_op_b} : {in_op_b[31], in_op_b};  // MULHSU/MULHU: unsigned
assign mul_full = mul_a * mul_b;

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        s1_valid      <= 1'b0;
        s1_tag        <= {TAG_W{1'b0}};
        s1_prod       <= 64'd0;
        s1_func3      <= 3'd0;
        s1_rd         <= 5'd0;
        s1_regs_write <= 1'b0;
        s1_fu         <= 3'd0;
        s1_tid        <= 1'b0;
        s1_order_id   <= {`METADATA_ORDER_ID_W{1'b0}};
    end else begin
        s1_valid      <= in_valid;
        s1_tag        <= in_tag;
        s1_prod       <= mul_full[63:0];
        s1_func3      <= in_func3;
        s1_rd         <= in_rd;
        s1_regs_write <= in_regs_write;
        s1_fu         <= in_fu;
        s1_tid        <= in_tid;
        s1_order_id   <= in_order_id;
    end
end

// ─── Stage 2: Pipeline register (balance timing) ───────────────────────────
always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        s2_valid      <= 1'b0;
        s2_tag        <= {TAG_W{1'b0}};
        s2_prod       <= 64'd0;
        s2_func3      <= 3'd0;
        s2_rd         <= 5'd0;
        s2_regs_write <= 1'b0;
        s2_fu         <= 3'd0;
        s2_tid        <= 1'b0;
        s2_order_id   <= {`METADATA_ORDER_ID_W{1'b0}};
    end else begin
        s2_valid      <= s1_valid;
        s2_tag        <= s1_tag;
        s2_prod       <= s1_prod;
        s2_func3      <= s1_func3;
        s2_rd         <= s1_rd;
        s2_regs_write <= s1_regs_write;
        s2_fu         <= s1_fu;
        s2_tid        <= s1_tid;
        s2_order_id   <= s1_order_id;
    end
end

// ─── Stage 3: Result selection ──────────────────────────────────────────────
wire [31:0] result_sel;
assign result_sel = (s2_func3 == 3'b000) ? s2_prod[31:0] : s2_prod[63:32];

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        s3_valid      <= 1'b0;
        s3_tag        <= {TAG_W{1'b0}};
        s3_result     <= 32'd0;
        s3_rd         <= 5'd0;
        s3_regs_write <= 1'b0;
        s3_fu         <= 3'd0;
        s3_tid        <= 1'b0;
        s3_order_id   <= {`METADATA_ORDER_ID_W{1'b0}};
    end else begin
        s3_valid      <= s2_valid;
        s3_tag        <= s2_tag;
        s3_result     <= result_sel;
        s3_rd         <= s2_rd;
        s3_regs_write <= s2_regs_write;
        s3_fu         <= s2_fu;
        s3_tid        <= s2_tid;
        s3_order_id   <= s2_order_id;
    end
end

// ─── Outputs ────────────────────────────────────────────────────────────────
assign out_valid      = s3_valid;
assign out_tag        = s3_tag;
assign out_result     = s3_result;
assign out_rd         = s3_rd;
assign out_regs_write = s3_regs_write;
assign out_fu         = s3_fu;
assign out_tid        = s3_tid;
assign out_order_id   = s3_order_id;

endmodule
