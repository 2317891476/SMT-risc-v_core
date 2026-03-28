`include "define.v"

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
    output wire         is_valid,
    // CSR/SYSTEM extension outputs
    output wire         is_system,       // SYSTEM opcode detected
    output wire         is_csr,          // CSR instruction (CSRRW/S/C/WI/SI/CI)
    output wire         is_mret,         // MRET instruction
    output wire [11:0]  csr_addr,        // CSR address from instruction
    // RoCC extension outputs
    output wire         is_rocc,         // RoCC CUSTOM0 instruction detected
    output wire [6:0]   rocc_funct7      // RoCC funct7 for command decoding
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

// CSR/SYSTEM decode
assign is_system = (opcode == `SYSTEM);
// CSR instructions have funct3 != 0, MRET is funct3=0 and bits[31:20]=0x302
assign is_csr    = is_system && (func3 != 3'b000);
assign is_mret   = is_system && (func3 == 3'b000) && (is_inst[31:20] == 12'h302);
assign csr_addr  = is_inst[31:20];

// RoCC decode
assign is_rocc    = (opcode == `OPC_CUSTOM0);
assign rocc_funct7 = is_inst[31:25];

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

// func7[0] indicates MUL instructions (func7 = 0000001)
wire func7_mul = is_inst[25];  // bit 25 of instruction = func7[0]

always @(*) begin
    is_fu = `FU_NOP;
    case (opcode)
        `Rtype: begin
            // RV32M multiplication instructions (func3 0,1,2,3,4 with func7=0000001)
            // MUL, MULH, MULHSU, MULHU need FU_MUL
            // Note: func7_code is inst[30] (func7[5]), but MUL uses func7=0000001
            // SUB uses func7=0100000, so we need to check func7[0] (inst[25])
            if (func7_mul && (func3 == 3'd0 || func3 == 3'd1 || func3 == 3'd2 || func3 == 3'd3 || func3 == 3'd4)) begin
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
        `SYSTEM: is_fu = `FU_INT0;  // SYSTEM (CSR/MRET) -> Pipe 0 for serialization
        `OPC_CUSTOM0: is_fu = `FU_INT0;  // RoCC -> Pipe 0 for serialization
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
        `SYSTEM: begin
            // CSR instructions: rs1 is used for non-immediate variants
            // funct3[2] = 0 means CSR reg (uses rs1), funct3[2] = 1 means CSR imm
            is_rs1_used = is_csr && !func3[2];  // CSRRW/S/C use rs1, CSRRWI/SI/CI don't
            is_rs2_used = 1'b0;
        end
        `OPC_CUSTOM0: begin
            // RoCC instructions: rs1 and rs2 used as operands
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
