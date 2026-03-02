module hazard_detection(
    input  wire      ex1_regs_write,
    input  wire[4:0] ex1_rd,
    input  wire      ex2_regs_write,
    input  wire[4:0] ex2_rd,
    input  wire      ex3_regs_write,
    input  wire[4:0] ex3_rd,
    input  wire      ex4_regs_write,
    input  wire[4:0] ex4_rd,
    input  wire      me_regs_write,
    input  wire[4:0] me_rd,
    input  wire[4:0] id_rs1,
    input  wire[4:0] id_rs2,
    input  wire      br_ctrl,
    output wire      stall,
    output wire      flush
);

wire raw_ex1;
wire raw_ex2;
wire raw_ex3;
wire raw_ex4;
wire raw_mem;

assign raw_ex1 = ex1_regs_write && (ex1_rd != 0) && ((ex1_rd == id_rs1) || (ex1_rd == id_rs2));
assign raw_ex2 = ex2_regs_write && (ex2_rd != 0) && ((ex2_rd == id_rs1) || (ex2_rd == id_rs2));
assign raw_ex3 = ex3_regs_write && (ex3_rd != 0) && ((ex3_rd == id_rs1) || (ex3_rd == id_rs2));
assign raw_ex4 = ex4_regs_write && (ex4_rd != 0) && ((ex4_rd == id_rs1) || (ex4_rd == id_rs2));
assign raw_mem = me_regs_write  && (me_rd  != 0) && ((me_rd  == id_rs1) || (me_rd  == id_rs2));

assign flush           = br_ctrl;
assign stall           = raw_ex1 || raw_ex2 || raw_ex3 || raw_ex4 || raw_mem;

endmodule
