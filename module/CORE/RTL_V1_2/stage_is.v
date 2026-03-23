`include "define_v2.v"

module stage_is(
    input  wire[31:0]   is_inst,
    input  wire[31:0]   is_pc,
    output wire[31:0]   is_pc_o,
    output wire[31:0]   is_imm,
    output wire[2:0]    is_func3_code,
    output wire         is_func7_code,
    output wire[4:0]    is_rd,
    output wire         is_br,
    output wire         is_mem_read,
    output wire         is_mem2reg,
    output wire[2:0]    is_alu_op,
    output wire         is_mem_write,
    output wire[1:0]    is_alu_src1,
    output wire[1:0]    is_alu_src2,
    output wire         is_br_addr_mode,
    output wire         is_regs_write,
    output wire[4:0]    is_rs1,
    output wire[4:0]    is_rs2,
    output reg          is_rs1_used,
    output reg          is_rs2_used,
    output reg[2:0]     is_fu,
    output wire         is_valid
);

wire[6:0] opcode;
wire[2:0] func3;
wire      func7_code;

assign opcode        = is_inst[6:0];
assign func3         = is_inst[14:12];
assign func7_code    = is_inst[30];
assign is_pc_o       = is_pc;
assign is_func3_code = func3;
assign is_func7_code = func7_code;
assign is_rd         = is_inst[11:7];
assign is_rs1        = is_inst[19:15];
assign is_rs2        = is_inst[24:20];

ctrl u_ctrl(
    .inst_op      (opcode         ),
    .br           (is_br          ),
    .mem_read     (is_mem_read    ),
    .mem2reg      (is_mem2reg     ),
    .alu_op       (is_alu_op      ),
    .mem_write    (is_mem_write   ),
    .alu_src1     (is_alu_src1    ),
    .alu_src2     (is_alu_src2    ),
    .br_addr_mode (is_br_addr_mode),
    .regs_write   (is_regs_write  )
);

imm_gen u_imm_gen(
    .inst  (is_inst),
    .imm_o (is_imm )
);

always @(*) begin
    is_fu = `FU_NOP;
    case (opcode)
        `Rtype: begin
            // RV32M multiplication instructions (func3 0,1,2,3,4 with func7=1)
            // MUL, MULH, MULHSU, MULHU need FU_MUL
            if (func7_code && (func3 == 3'd0 || func3 == 3'd1 || func3 == 3'd2 || func3 == 3'd3 || func3 == 3'd4)) begin
                is_fu = `FU_MUL;
            end else begin
                is_fu = `FU_INT1;  // R-type ALU -> Pipe 1
            end
        end
        `ItypeA: is_fu = `FU_INT1;  // ALU immediate -> Pipe 1
        `ItypeL: is_fu = `FU_LOAD;  // Load -> Pipe 1 (MEM)
        `Stype : is_fu = `FU_STORE; // Store -> Pipe 1 (MEM)
        `UtypeL: is_fu = `FU_INT0;  // LUI -> Pipe 0
        `UtypeU: is_fu = `FU_INT0;  // AUIPC -> Pipe 0
        `Btype : is_fu = `FU_INT0;  // Branch -> Pipe 0 (has branch resolution)
        `ItypeJ: is_fu = `FU_INT0;  // JALR -> Pipe 0
        `Jtype : is_fu = `FU_INT0;  // JAL -> Pipe 0
        default: is_fu = `FU_NOP;
    endcase
end

always @(*) begin
    is_rs1_used = 1'b0;
    is_rs2_used = 1'b0;
    case (opcode)
        `Rtype: begin
            is_rs1_used = 1'b1;
            is_rs2_used = 1'b1;
        end
        `ItypeA,
        `ItypeL,
        `ItypeJ: begin
            is_rs1_used = 1'b1;
            is_rs2_used = 1'b0;
        end
        `Stype,
        `Btype: begin
            is_rs1_used = 1'b1;
            is_rs2_used = 1'b1;
        end
        default: begin
            is_rs1_used = 1'b0;
            is_rs2_used = 1'b0;
        end
    endcase
end

assign is_valid = (is_fu != 3'd0);

endmodule
