module reg_ex_stage(
    input  wire        clk,
    input  wire        rstn,
    input  wire[31:0]  in_regs_data2,
    input  wire[31:0]  in_alu_o,
    input  wire[4:0]   in_rd,
    input  wire        in_mem_read,
    input  wire        in_mem2reg,
    input  wire        in_mem_write,
    input  wire        in_regs_write,
    input  wire[2:0]   in_func3_code,
    input  wire[2:0]   in_fu,
    input  wire[3:0]   in_sb_tag,
    input  wire[0:0]   in_tid,
    output reg[31:0]   out_regs_data2,
    output reg[31:0]   out_alu_o,
    output reg[4:0]    out_rd,
    output reg         out_mem_read,
    output reg         out_mem2reg,
    output reg         out_mem_write,
    output reg         out_regs_write,
    output reg[2:0]    out_func3_code,
    output reg[2:0]    out_fu,
    output reg[3:0]    out_sb_tag,
    output reg[0:0]    out_tid
);

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        out_regs_data2 <= 32'd0;
        out_alu_o      <= 32'd0;
        out_rd         <= 5'd0;
        out_mem_read   <= 1'b0;
        out_mem2reg    <= 1'b0;
        out_mem_write  <= 1'b0;
        out_regs_write <= 1'b0;
        out_func3_code <= 3'd0;
        out_fu         <= 3'd0;
        out_sb_tag     <= 4'd0;
        out_tid        <= 1'b0;
    end
    else begin
        out_regs_data2 <= in_regs_data2;
        out_alu_o      <= in_alu_o;
        out_rd         <= in_rd;
        out_mem_read   <= in_mem_read;
        out_mem2reg    <= in_mem2reg;
        out_mem_write  <= in_mem_write;
        out_regs_write <= in_regs_write;
        out_func3_code <= in_func3_code;
        out_fu         <= in_fu;
        out_sb_tag     <= in_sb_tag;
        out_tid        <= in_tid;
    end
end

endmodule
