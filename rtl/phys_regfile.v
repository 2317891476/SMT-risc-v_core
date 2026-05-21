`timescale 1ns/1ns
// =============================================================================
// Module : phys_regfile
// Description: Physical Register File for rename-based OoO backend.
//   64 registers (32 arch + 32 extra for renaming).
//   4 combinational read ports (2 per execution pipe), 2 write ports (WB).
//   x0 hard-wired to zero.  Same-cycle write→read forwarding.
// =============================================================================
`include "define.v"

module phys_regfile #(
    parameter NUM_PHYS_REG = 64,
    parameter PHYS_REG_W   = 6,
    parameter DATA_W       = 32
)(
    input  wire        clk,
    input  wire        rstn,

    // Read Port 0 (pipe 0 rs1)
    input  wire [PHYS_REG_W-1:0]    r0_addr,
    output wire [DATA_W-1:0]        r0_data,

    // Read Port 1 (pipe 0 rs2)
    input  wire [PHYS_REG_W-1:0]    r1_addr,
    output wire [DATA_W-1:0]        r1_data,

    // Read Port 2 (pipe 1 rs1)
    input  wire [PHYS_REG_W-1:0]    r2_addr,
    output wire [DATA_W-1:0]        r2_data,

    // Read Port 3 (pipe 1 rs2)
    input  wire [PHYS_REG_W-1:0]    r3_addr,
    output wire [DATA_W-1:0]        r3_data,

    // Write Port 0 (WB pipe 0)
    input  wire                     w0_en,
    input  wire [PHYS_REG_W-1:0]    w0_addr,
    input  wire [DATA_W-1:0]        w0_data,

    // Write Port 1 (WB pipe 1)
    input  wire                     w1_en,
    input  wire [PHYS_REG_W-1:0]    w1_addr,
    input  wire [DATA_W-1:0]        w1_data
);

    reg [DATA_W-1:0] prf [0:NUM_PHYS_REG-1];

    integer r;
    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            for (r = 0; r < NUM_PHYS_REG; r = r + 1)
                prf[r] <= {DATA_W{1'b0}};
        end
        else begin
            if (w0_en && w0_addr != {PHYS_REG_W{1'b0}})
                prf[w0_addr] <= w0_data;
            if (w1_en && w1_addr != {PHYS_REG_W{1'b0}})
                prf[w1_addr] <= w1_data;
        end
    end

    wire w0_fwd_r0 = w0_en && (w0_addr == r0_addr) && (r0_addr != {PHYS_REG_W{1'b0}});
    wire w1_fwd_r0 = w1_en && (w1_addr == r0_addr) && (r0_addr != {PHYS_REG_W{1'b0}});
    wire w0_fwd_r1 = w0_en && (w0_addr == r1_addr) && (r1_addr != {PHYS_REG_W{1'b0}});
    wire w1_fwd_r1 = w1_en && (w1_addr == r1_addr) && (r1_addr != {PHYS_REG_W{1'b0}});
    wire w0_fwd_r2 = w0_en && (w0_addr == r2_addr) && (r2_addr != {PHYS_REG_W{1'b0}});
    wire w1_fwd_r2 = w1_en && (w1_addr == r2_addr) && (r2_addr != {PHYS_REG_W{1'b0}});
    wire w0_fwd_r3 = w0_en && (w0_addr == r3_addr) && (r3_addr != {PHYS_REG_W{1'b0}});
    wire w1_fwd_r3 = w1_en && (w1_addr == r3_addr) && (r3_addr != {PHYS_REG_W{1'b0}});

    assign r0_data = (r0_addr == {PHYS_REG_W{1'b0}}) ? {DATA_W{1'b0}} :
                     w1_fwd_r0 ? w1_data :
                     w0_fwd_r0 ? w0_data :
                     prf[r0_addr];

    assign r1_data = (r1_addr == {PHYS_REG_W{1'b0}}) ? {DATA_W{1'b0}} :
                     w1_fwd_r1 ? w1_data :
                     w0_fwd_r1 ? w0_data :
                     prf[r1_addr];

    assign r2_data = (r2_addr == {PHYS_REG_W{1'b0}}) ? {DATA_W{1'b0}} :
                     w1_fwd_r2 ? w1_data :
                     w0_fwd_r2 ? w0_data :
                     prf[r2_addr];

    assign r3_data = (r3_addr == {PHYS_REG_W{1'b0}}) ? {DATA_W{1'b0}} :
                     w1_fwd_r3 ? w1_data :
                     w0_fwd_r3 ? w0_data :
                     prf[r3_addr];

endmodule
