// regs_mt.v
// Multi-Thread Register File (N_T=2 banks, 32 x 32-bit each)
// Read port uses r_thread_id to select bank.
// Write port uses w_thread_id to select bank.
// Same-cycle WB hazard bypass is scoped to the same thread.

module regs_mt #(
    parameter N_T = 2
)(
    input  wire          clk,
    input  wire          rstn,

    // Read port
    input  wire [0:0]    r_thread_id,
    input  wire [4:0]    r_regs_addr1,
    input  wire [4:0]    r_regs_addr2,

    // Write port (from WB stage)
    input  wire [0:0]    w_thread_id,
    input  wire [4:0]    w_regs_addr,
    input  wire [31:0]   w_regs_data,
    input  wire          w_regs_en,

    output wire [31:0]   r_regs_o1,
    output wire [31:0]   r_regs_o2
);

// Two banks of 32 registers
reg [31:0] reg_bank [0:N_T-1][0:31];

integer i, b;

// -----------------------------------------------------------
// Write
// -----------------------------------------------------------
always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        for (b = 0; b < N_T; b = b + 1) begin
            for (i = 0; i < 32; i = i + 1) begin
                reg_bank[b][i] <= 32'd0;
            end
        end
    end
    else if (w_regs_en && (w_regs_addr != 5'd0)) begin
        `ifndef SYNTHESIS
        $display("WRITE T%0d x%0d = %h", w_thread_id, w_regs_addr, w_regs_data);
        `endif
        reg_bank[w_thread_id][w_regs_addr] <= w_regs_data;
    end
end

// -----------------------------------------------------------
// Read with WB-same-cycle forwarding (only within same thread)
// -----------------------------------------------------------
wire wb_hazard_a = w_regs_en &&
                   (w_regs_addr != 5'd0) &&
                   (w_regs_addr == r_regs_addr1) &&
                   (w_thread_id == r_thread_id);

wire wb_hazard_b = w_regs_en &&
                   (w_regs_addr != 5'd0) &&
                   (w_regs_addr == r_regs_addr2) &&
                   (w_thread_id == r_thread_id);

assign r_regs_o1 = wb_hazard_a ? w_regs_data : reg_bank[r_thread_id][r_regs_addr1];
assign r_regs_o2 = wb_hazard_b ? w_regs_data : reg_bank[r_thread_id][r_regs_addr2];

endmodule
