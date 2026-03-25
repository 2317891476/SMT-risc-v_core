module reg_is_ro(
    input  wire        clk,
    input  wire        rstn,
    input  wire        flush,
    input  wire [0:0]  flush_tid,  // SMT: only flush if current entry belongs to this thread
    input  wire        issue_en,
    input  wire        ro_fire,
    input  wire[31:0]  issue_pc,
    input  wire[31:0]  issue_imm,
    input  wire[2:0]   issue_func3_code,
    input  wire        issue_func7_code,
    input  wire[4:0]   issue_rd,
    input  wire        issue_br,
    input  wire        issue_mem_read,
    input  wire        issue_mem2reg,
    input  wire[2:0]   issue_alu_op,
    input  wire        issue_mem_write,
    input  wire[1:0]   issue_alu_src1,
    input  wire[1:0]   issue_alu_src2,
    input  wire        issue_br_addr_mode,
    input  wire        issue_regs_write,
    input  wire[4:0]   issue_rs1,
    input  wire[4:0]   issue_rs2,
    input  wire        issue_rs1_used,
    input  wire        issue_rs2_used,
    input  wire[2:0]   issue_fu,
    input  wire[3:0]   issue_sb_tag,
    input  wire[0:0]   issue_tid,
    output reg         ro_valid,
    output reg[31:0]   ro_pc,
    output reg[31:0]   ro_imm,
    output reg[2:0]    ro_func3_code,
    output reg         ro_func7_code,
    output reg[4:0]    ro_rd,
    output reg         ro_br,
    output reg         ro_mem_read,
    output reg         ro_mem2reg,
    output reg[2:0]    ro_alu_op,
    output reg         ro_mem_write,
    output reg[1:0]    ro_alu_src1,
    output reg[1:0]    ro_alu_src2,
    output reg         ro_br_addr_mode,
    output reg         ro_regs_write,
    output reg[4:0]    ro_rs1,
    output reg[4:0]    ro_rs2,
    output reg         ro_rs1_used,
    output reg         ro_rs2_used,
    output reg[2:0]    ro_fu,
    output reg[3:0]    ro_sb_tag,
    output reg[0:0]    ro_tid
);

always @(posedge clk or negedge rstn) begin
    if (!rstn || (flush && (ro_tid == flush_tid))) begin
        ro_valid       <= 1'b0;
        ro_pc          <= 32'd0;
        ro_imm         <= 32'd0;
        ro_func3_code  <= 3'd0;
        ro_func7_code  <= 1'b0;
        ro_rd          <= 5'd0;
        ro_br          <= 1'b0;
        ro_mem_read    <= 1'b0;
        ro_mem2reg     <= 1'b0;
        ro_alu_op      <= 3'd0;
        ro_mem_write   <= 1'b0;
        ro_alu_src1    <= 2'd0;
        ro_alu_src2    <= 2'd0;
        ro_br_addr_mode<= 1'b0;
        ro_regs_write  <= 1'b0;
        ro_rs1         <= 5'd0;
        ro_rs2         <= 5'd0;
        ro_rs1_used    <= 1'b0;
        ro_rs2_used    <= 1'b0;
        ro_fu          <= 3'd0;
        ro_sb_tag      <= 4'd0;
        ro_tid         <= 1'b0;
    end
    else begin
        case ({ro_fire, issue_en})
            2'b00: begin
                ro_valid <= ro_valid;
            end
            2'b01: begin
                ro_valid        <= 1'b1;
                ro_pc           <= issue_pc;
                ro_imm          <= issue_imm;
                ro_func3_code   <= issue_func3_code;
                ro_func7_code   <= issue_func7_code;
                ro_rd           <= issue_rd;
                ro_br           <= issue_br;
                ro_mem_read     <= issue_mem_read;
                ro_mem2reg      <= issue_mem2reg;
                ro_alu_op       <= issue_alu_op;
                ro_mem_write    <= issue_mem_write;
                ro_alu_src1     <= issue_alu_src1;
                ro_alu_src2     <= issue_alu_src2;
                ro_br_addr_mode <= issue_br_addr_mode;
                ro_regs_write   <= issue_regs_write;
                ro_rs1          <= issue_rs1;
                ro_rs2          <= issue_rs2;
                ro_rs1_used     <= issue_rs1_used;
                ro_rs2_used     <= issue_rs2_used;
                ro_fu           <= issue_fu;
                ro_sb_tag       <= issue_sb_tag;
                ro_tid          <= issue_tid;
            end
            2'b10: begin
                ro_valid        <= 1'b0;
                ro_pc           <= 32'd0;
                ro_imm          <= 32'd0;
                ro_func3_code   <= 3'd0;
                ro_func7_code   <= 1'b0;
                ro_rd           <= 5'd0;
                ro_br           <= 1'b0;
                ro_mem_read     <= 1'b0;
                ro_mem2reg      <= 1'b0;
                ro_alu_op       <= 3'd0;
                ro_mem_write    <= 1'b0;
                ro_alu_src1     <= 2'd0;
                ro_alu_src2     <= 2'd0;
                ro_br_addr_mode <= 1'b0;
                ro_regs_write   <= 1'b0;
                ro_rs1          <= 5'd0;
                ro_rs2          <= 5'd0;
                ro_rs1_used     <= 1'b0;
                ro_rs2_used     <= 1'b0;
                ro_fu           <= 3'd0;
                ro_sb_tag       <= 4'd0;
                ro_tid          <= 1'b0;
            end
            2'b11: begin
                ro_valid        <= 1'b1;
                ro_pc           <= issue_pc;
                ro_imm          <= issue_imm;
                ro_func3_code   <= issue_func3_code;
                ro_func7_code   <= issue_func7_code;
                ro_rd           <= issue_rd;
                ro_br           <= issue_br;
                ro_mem_read     <= issue_mem_read;
                ro_mem2reg      <= issue_mem2reg;
                ro_alu_op       <= issue_alu_op;
                ro_mem_write    <= issue_mem_write;
                ro_alu_src1     <= issue_alu_src1;
                ro_alu_src2     <= issue_alu_src2;
                ro_br_addr_mode <= issue_br_addr_mode;
                ro_regs_write   <= issue_regs_write;
                ro_rs1          <= issue_rs1;
                ro_rs2          <= issue_rs2;
                ro_rs1_used     <= issue_rs1_used;
                ro_rs2_used     <= issue_rs2_used;
                ro_fu           <= issue_fu;
                ro_sb_tag       <= issue_sb_tag;
                ro_tid          <= issue_tid;
            end
        endcase
    end
end

endmodule
