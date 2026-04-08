`timescale 1ns/1ns
// =============================================================================
// Module : phys_regfile
// Description: Physical Register File for rename-based OoO backend.
//   48 registers per thread (32 arch + 16 extra for renaming).
//   4 combinational read ports (2 per execution pipe), 2 write ports (WB).
//   x0 hard-wired to zero.  Same-cycle write→read forwarding.
// =============================================================================
`include "define.v"

module phys_regfile #(
    parameter NUM_PHYS_REG = 48,
    parameter PHYS_REG_W   = 6,   // clog2(48) ≈ 6
    parameter NUM_THREAD   = 2,
    parameter DATA_W       = 32
)(
    input  wire        clk,
    input  wire        rstn,

    // ─── Read Port 0 (pipe 0 rs1) ───────────────────────────────
    input  wire [0:0]               r0_tid,
    input  wire [PHYS_REG_W-1:0]    r0_addr,
    output wire [DATA_W-1:0]        r0_data,

    // ─── Read Port 1 (pipe 0 rs2) ───────────────────────────────
    input  wire [0:0]               r1_tid,
    input  wire [PHYS_REG_W-1:0]    r1_addr,
    output wire [DATA_W-1:0]        r1_data,

    // ─── Read Port 2 (pipe 1 rs1) ───────────────────────────────
    input  wire [0:0]               r2_tid,
    input  wire [PHYS_REG_W-1:0]    r2_addr,
    output wire [DATA_W-1:0]        r2_data,

    // ─── Read Port 3 (pipe 1 rs2) ───────────────────────────────
    input  wire [0:0]               r3_tid,
    input  wire [PHYS_REG_W-1:0]    r3_addr,
    output wire [DATA_W-1:0]        r3_data,

    // ─── Write Port 0 (WB pipe 0) ───────────────────────────────
    input  wire                     w0_en,
    input  wire [0:0]               w0_tid,
    input  wire [PHYS_REG_W-1:0]    w0_addr,
    input  wire [DATA_W-1:0]        w0_data,

    // ─── Write Port 1 (WB pipe 1) ───────────────────────────────
    input  wire                     w1_en,
    input  wire [0:0]               w1_tid,
    input  wire [PHYS_REG_W-1:0]    w1_addr,
    input  wire [DATA_W-1:0]        w1_data
);

    // Storage: 2D array [thread][phys_reg]
    reg [DATA_W-1:0] prf [0:NUM_THREAD-1][0:NUM_PHYS_REG-1];

    // ═══ Write (sequential) ═══
    integer t, r;
    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            for (t = 0; t < NUM_THREAD; t = t + 1)
                for (r = 0; r < NUM_PHYS_REG; r = r + 1)
                    prf[t][r] <= {DATA_W{1'b0}};
        end
        else begin
            if (w0_en && w0_addr != {PHYS_REG_W{1'b0}})
                prf[w0_tid][w0_addr] <= w0_data;
            if (w1_en && w1_addr != {PHYS_REG_W{1'b0}})
                prf[w1_tid][w1_addr] <= w1_data;
        end
    end

    // ═══ Read (combinational with same-cycle forwarding) ═══
    // Write port priority: w1 > w0 (both same addr/tid → w1 wins)
    // If writing this cycle to the same addr, forward the new data

    wire w0_fwd_r0 = w0_en && (w0_tid == r0_tid) && (w0_addr == r0_addr) && (r0_addr != {PHYS_REG_W{1'b0}});
    wire w1_fwd_r0 = w1_en && (w1_tid == r0_tid) && (w1_addr == r0_addr) && (r0_addr != {PHYS_REG_W{1'b0}});
    wire w0_fwd_r1 = w0_en && (w0_tid == r1_tid) && (w0_addr == r1_addr) && (r1_addr != {PHYS_REG_W{1'b0}});
    wire w1_fwd_r1 = w1_en && (w1_tid == r1_tid) && (w1_addr == r1_addr) && (r1_addr != {PHYS_REG_W{1'b0}});
    wire w0_fwd_r2 = w0_en && (w0_tid == r2_tid) && (w0_addr == r2_addr) && (r2_addr != {PHYS_REG_W{1'b0}});
    wire w1_fwd_r2 = w1_en && (w1_tid == r2_tid) && (w1_addr == r2_addr) && (r2_addr != {PHYS_REG_W{1'b0}});
    wire w0_fwd_r3 = w0_en && (w0_tid == r3_tid) && (w0_addr == r3_addr) && (r3_addr != {PHYS_REG_W{1'b0}});
    wire w1_fwd_r3 = w1_en && (w1_tid == r3_tid) && (w1_addr == r3_addr) && (r3_addr != {PHYS_REG_W{1'b0}});

    // p0 always reads 0 for phys reg 0
    assign r0_data = (r0_addr == {PHYS_REG_W{1'b0}}) ? {DATA_W{1'b0}} :
                     w1_fwd_r0 ? w1_data :
                     w0_fwd_r0 ? w0_data :
                     prf[r0_tid][r0_addr];

    assign r1_data = (r1_addr == {PHYS_REG_W{1'b0}}) ? {DATA_W{1'b0}} :
                     w1_fwd_r1 ? w1_data :
                     w0_fwd_r1 ? w0_data :
                     prf[r1_tid][r1_addr];

    assign r2_data = (r2_addr == {PHYS_REG_W{1'b0}}) ? {DATA_W{1'b0}} :
                     w1_fwd_r2 ? w1_data :
                     w0_fwd_r2 ? w0_data :
                     prf[r2_tid][r2_addr];

    assign r3_data = (r3_addr == {PHYS_REG_W{1'b0}}) ? {DATA_W{1'b0}} :
                     w1_fwd_r3 ? w1_data :
                     w0_fwd_r3 ? w0_data :
                     prf[r3_tid][r3_addr];

endmodule
