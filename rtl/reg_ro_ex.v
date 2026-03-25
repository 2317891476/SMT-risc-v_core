module reg_ro_ex(
    input  wire        clk,
    input  wire        rstn,
    input  wire        flush,
    input  wire [0:0]  flush_tid,  // SMT: only flush if content belongs to this thread
    input  wire        ro_fire,
    input  wire[31:0]  ro_pc,
    input  wire[31:0]  ro_regs_data1,
    input  wire[31:0]  ro_regs_data2,
    input  wire[31:0]  ro_imm,
    input  wire[2:0]   ro_func3_code,
    input  wire        ro_func7_code,
    input  wire[4:0]   ro_rd,
    input  wire        ro_br,
    input  wire        ro_mem_read,
    input  wire        ro_mem2reg,
    input  wire[2:0]   ro_alu_op,
    input  wire        ro_mem_write,
    input  wire[1:0]   ro_alu_src1,
    input  wire[1:0]   ro_alu_src2,
    input  wire        ro_br_addr_mode,
    input  wire        ro_regs_write,
    input  wire[2:0]   ro_fu,
    input  wire[3:0]   ro_sb_tag,
    input  wire[0:0]   ro_tid,
    output reg[31:0]   ex_pc,
    output reg[31:0]   ex_regs_data1,
    output reg[31:0]   ex_regs_data2,
    output reg[31:0]   ex_imm,
    output reg[2:0]    ex_func3_code,
    output reg         ex_func7_code,
    output reg[4:0]    ex_rd,
    output reg         ex_br,
    output reg         ex_mem_read,
    output reg         ex_mem2reg,
    output reg[2:0]    ex_alu_op,
    output reg         ex_mem_write,
    output reg[1:0]    ex_alu_src1,
    output reg[1:0]    ex_alu_src2,
    output reg         ex_br_addr_mode,
    output reg         ex_regs_write,
    output reg[2:0]    ex_fu,
    output reg[3:0]    ex_sb_tag,
    output reg[0:0]    ex_tid
);

always @(posedge clk or negedge rstn) begin
    if (!rstn || (flush && (ex_tid == flush_tid))) begin
        ex_pc           <= 32'd0;
        ex_regs_data1   <= 32'd0;
        ex_regs_data2   <= 32'd0;
        ex_imm          <= 32'd0;
        ex_func3_code   <= 3'd0;
        ex_func7_code   <= 1'b0;
        ex_rd           <= 5'd0;
        ex_br           <= 1'b0;
        ex_mem_read     <= 1'b0;
        ex_mem2reg      <= 1'b0;
        ex_alu_op       <= 3'd0;
        ex_mem_write    <= 1'b0;
        ex_alu_src1     <= 2'd0;
        ex_alu_src2     <= 2'd0;
        ex_br_addr_mode <= 1'b0;
        ex_regs_write   <= 1'b0;
        ex_fu           <= 3'd0;
        ex_sb_tag       <= 4'd0;
        ex_tid          <= 1'b0;
    end
    else if (ro_fire) begin
        ex_pc           <= ro_pc;
        ex_regs_data1   <= ro_regs_data1;
        ex_regs_data2   <= ro_regs_data2;
        ex_imm          <= ro_imm;
        ex_func3_code   <= ro_func3_code;
        ex_func7_code   <= ro_func7_code;
        ex_rd           <= ro_rd;
        ex_br           <= ro_br;
        ex_mem_read     <= ro_mem_read;
        ex_mem2reg      <= ro_mem2reg;
        ex_alu_op       <= ro_alu_op;
        ex_mem_write    <= ro_mem_write;
        ex_alu_src1     <= ro_alu_src1;
        ex_alu_src2     <= ro_alu_src2;
        ex_br_addr_mode <= ro_br_addr_mode;
        ex_regs_write   <= ro_regs_write;
        ex_fu           <= ro_fu;
        ex_sb_tag       <= ro_sb_tag;
        ex_tid          <= ro_tid;
    end
    else begin
        ex_pc           <= 32'd0;
        ex_regs_data1   <= 32'd0;
        ex_regs_data2   <= 32'd0;
        ex_imm          <= 32'd0;
        ex_func3_code   <= 3'd0;
        ex_func7_code   <= 1'b0;
        ex_rd           <= 5'd0;
        ex_br           <= 1'b0;
        ex_mem_read     <= 1'b0;
        ex_mem2reg      <= 1'b0;
        ex_alu_op       <= 3'd0;
        ex_mem_write    <= 1'b0;
        ex_alu_src1     <= 2'd0;
        ex_alu_src2     <= 2'd0;
        ex_br_addr_mode <= 1'b0;
        ex_regs_write   <= 1'b0;
        ex_fu           <= 3'd0;
        ex_sb_tag       <= 4'd0;
        ex_tid          <= 1'b0;
    end
end

endmodule
