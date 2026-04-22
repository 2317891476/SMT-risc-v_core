// =============================================================================
// Module : div_unit
// Description: 33-cycle sequential restoring divider for RV32M extension.
//   Supports: DIV, DIVU, REM, REMU (func3 4,5,6,7)
//   Cycle 0: capture + special cases (div-by-zero, overflow)
//   Cycles 1-32: one quotient bit per cycle (restoring division)
//   Cycle 33: sign correction and output
// =============================================================================
module div_unit #(
    parameter TAG_W = 5
)(
    input  wire               clk,
    input  wire               rstn,

    input  wire               in_valid,
    input  wire [TAG_W-1:0]   in_tag,
    input  wire [31:0]        in_op_a,
    input  wire [31:0]        in_op_b,
    input  wire [2:0]         in_func3,
    input  wire [4:0]         in_rd,
    input  wire               in_regs_write,
    input  wire [2:0]         in_fu,
    input  wire [0:0]         in_tid,

    output wire               out_valid,
    output wire [TAG_W-1:0]   out_tag,
    output wire [31:0]        out_result,
    output wire [4:0]         out_rd,
    output wire               out_regs_write,
    output wire [2:0]         out_fu,
    output wire [0:0]         out_tid,

    output wire               busy
);

reg        running;
reg [5:0]  cnt;           // 0..32
reg [31:0] quo;
reg [32:0] rem;           // 33-bit for subtraction borrow
reg [31:0] dvsr;
reg        neg_quo;
reg        neg_rem;
reg        want_rem;

reg [TAG_W-1:0] sv_tag;
reg [4:0]       sv_rd;
reg             sv_regs_write;
reg [2:0]       sv_fu;
reg [0:0]       sv_tid;

reg             done_r;
reg [31:0]      result_r;

wire is_signed   = !in_func3[0];
wire div_by_zero = (in_op_b == 32'd0);
wire overflow    = is_signed && (in_op_a == 32'h80000000) && (in_op_b == 32'hFFFFFFFF);

wire [31:0] abs_a = (is_signed && in_op_a[31]) ? (~in_op_a + 32'd1) : in_op_a;
wire [31:0] abs_b = (is_signed && in_op_b[31]) ? (~in_op_b + 32'd1) : in_op_b;

// Division iteration: shift left and trial subtract
wire [32:0] shifted = {rem[31:0], quo[31]};
wire [32:0] trial   = shifted - {1'b0, dvsr};

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        running     <= 1'b0;
        cnt         <= 6'd0;
        quo         <= 32'd0;
        rem         <= 33'd0;
        dvsr        <= 32'd0;
        neg_quo     <= 1'b0;
        neg_rem     <= 1'b0;
        want_rem    <= 1'b0;
        done_r      <= 1'b0;
        result_r    <= 32'd0;
        sv_tag      <= {TAG_W{1'b0}};
        sv_rd       <= 5'd0;
        sv_regs_write <= 1'b0;
        sv_fu       <= 3'd0;
        sv_tid      <= 1'b0;
    end else begin
        done_r <= 1'b0;

`ifdef VERBOSE_SIM_LOGS
        if (in_valid && !running) begin
            $display("[DIV_IN] t=%0t op_a=%h op_b=%h func3=%0d rd=%0d tag=%0d",
                     $time, in_op_a, in_op_b, in_func3, in_rd, in_tag);
        end
        if (done_r) begin
            $display("[DIV_OUT] t=%0t result=%h rd=%0d tag=%0d",
                     $time, result_r, sv_rd, sv_tag);
        end
`endif

        if (!running) begin
            if (in_valid) begin
                sv_tag       <= in_tag;
                sv_rd        <= in_rd;
                sv_regs_write<= in_regs_write;
                sv_fu        <= in_fu;
                sv_tid       <= in_tid;
                want_rem     <= in_func3[1];

                if (div_by_zero) begin
                    done_r   <= 1'b1;
                    result_r <= in_func3[1] ? in_op_a : 32'hFFFFFFFF;
                end else if (overflow) begin
                    done_r   <= 1'b1;
                    result_r <= in_func3[1] ? 32'd0 : 32'h80000000;
                end else begin
                    running  <= 1'b1;
                    cnt      <= 6'd0;
                    quo      <= abs_a;
                    rem      <= 33'd0;
                    dvsr     <= abs_b;
                    neg_quo  <= is_signed && (in_op_a[31] ^ in_op_b[31]);
                    neg_rem  <= is_signed && in_op_a[31];
                end
            end
        end else begin
            // Restoring division: one bit per cycle
            if (!trial[32]) begin
                rem <= trial;
                quo <= {quo[30:0], 1'b1};
            end else begin
                rem <= shifted;
                quo <= {quo[30:0], 1'b0};
            end

            cnt <= cnt + 6'd1;

            if (cnt == 6'd31) begin
                running <= 1'b0;
                done_r  <= 1'b1;
                // Result computed from NEXT iteration's values
                if (want_rem) begin
                    if (!trial[32])
                        result_r <= neg_rem ? (~trial[31:0] + 32'd1) : trial[31:0];
                    else
                        result_r <= neg_rem ? (~shifted[31:0] + 32'd1) : shifted[31:0];
                end else begin
                    if (!trial[32])
                        result_r <= neg_quo ? (~{quo[30:0], 1'b1} + 32'd1) : {quo[30:0], 1'b1};
                    else
                        result_r <= neg_quo ? (~{quo[30:0], 1'b0} + 32'd1) : {quo[30:0], 1'b0};
                end
            end
        end
    end
end

assign busy       = running;
assign out_valid  = done_r;
assign out_tag    = sv_tag;
assign out_result = result_r;
assign out_rd     = sv_rd;
assign out_regs_write = sv_regs_write;
assign out_fu     = sv_fu;
assign out_tid    = sv_tid;

endmodule
