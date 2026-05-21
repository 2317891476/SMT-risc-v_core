// pc_mt.v
// Single-Thread PC Manager
// Maintains pc and pc_next for the single thread.

module pc_mt(
    input  wire          clk,
    input  wire          rstn,

    // Branch redirect
    input  wire          br_ctrl,
    input  wire [31:0]   br_addr,

    // Predicted redirect for the fetch just launched
    input  wire          pred_ctrl,
    input  wire [31:0]   pred_addr,

    // Stall / advance
    input  wire          pc_stall,
    input  wire          pc_advance,

    // Outputs: the PC sent to IF stage
    output reg  [31:0]   if_pc
);

reg [31:0] pc;
reg [31:0] pc_next;

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
`ifdef VERILATOR_MAINLINE_PRELOAD_BOOT
        pc      <= 32'h80000000;
        pc_next <= 32'h80000004;
`else
        pc      <= 32'h00000000;
        pc_next <= 32'h00000004;
`endif
    end
    else begin
        if (br_ctrl) begin
            pc      <= br_addr;
            pc_next <= br_addr + 32'h4;
        end
        else if (pc_stall) begin
            pc      <= pc;
            pc_next <= pc_next;
        end
        else if (pc_advance) begin
            if (pred_ctrl) begin
                pc      <= pred_addr;
                pc_next <= pred_addr + 32'h4;
            end else begin
                pc      <= pc_next;
                pc_next <= pc_next + 32'h4;
            end
        end
    end
end

always @(*) begin
    if_pc = pc;
end

endmodule
