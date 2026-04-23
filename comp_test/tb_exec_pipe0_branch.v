`timescale 1ns/1ps
`include "../rtl/define.v"

module tb_exec_pipe0_branch;
reg         clk;
reg         rstn;
reg         in_valid;
reg  [4:0]  in_tag;
reg  [31:0] in_pc;
reg  [31:0] in_op_a;
reg  [31:0] in_op_b;
reg  [4:0]  in_rs1_idx;
reg  [31:0] in_imm;
reg  [15:0] in_order_id;
reg         in_pred_taken;
reg  [31:0] in_pred_target;
reg         in_pred_hit;
reg  [1:0]  in_pred_type;
reg  [2:0]  in_func3;
reg         in_func7;
reg  [2:0]  in_alu_op;
reg  [1:0]  in_alu_src1;
reg  [1:0]  in_alu_src2;
reg         in_br_addr_mode;
reg         in_br;
reg  [4:0]  in_rd;
reg         in_regs_write;
reg  [2:0]  in_fu;
reg  [0:0]  in_tid;
reg         in_is_csr;
reg         in_is_mret;
reg  [11:0] in_csr_addr;
reg  [31:0] csr_rdata;

wire        br_resolve_valid;
wire        br_actual_taken;
wire [31:0] br_actual_target;
wire [1:0]  br_resolve_type;
wire        br_pred_taken;
wire [31:0] br_pred_target;
wire        br_pred_hit;
wire        br_mispredict;
wire [31:0] br_redirect_pc;

exec_pipe0 #(.TAG_W(5)) dut (
    .clk             (clk),
    .rstn            (rstn),
    .in_valid        (in_valid),
    .in_tag          (in_tag),
    .in_pc           (in_pc),
    .in_op_a         (in_op_a),
    .in_op_b         (in_op_b),
    .in_rs1_idx      (in_rs1_idx),
    .in_imm          (in_imm),
    .in_order_id     (in_order_id),
    .in_pred_taken   (in_pred_taken),
    .in_pred_target  (in_pred_target),
    .in_pred_hit     (in_pred_hit),
    .in_pred_type    (in_pred_type),
    .in_func3        (in_func3),
    .in_func7        (in_func7),
    .in_alu_op       (in_alu_op),
    .in_alu_src1     (in_alu_src1),
    .in_alu_src2     (in_alu_src2),
    .in_br_addr_mode (in_br_addr_mode),
    .in_br           (in_br),
    .in_rd           (in_rd),
    .in_regs_write   (in_regs_write),
    .in_fu           (in_fu),
    .in_tid          (in_tid),
    .in_is_csr       (in_is_csr),
    .in_is_mret      (in_is_mret),
    .in_csr_addr     (in_csr_addr),
    .csr_rdata       (csr_rdata),
    .out_valid       (),
    .out_tag         (),
    .out_result      (),
    .out_rd          (),
    .out_regs_write  (),
    .out_fu          (),
    .out_tid         (),
    .csr_valid       (),
    .csr_wdata       (),
    .csr_op          (),
    .csr_addr        (),
    .mret_valid      (),
    .br_ctrl         (),
    .br_addr         (),
    .br_pc           (),
    .br_tid          (),
    .br_order_id     (),
    .br_complete     (),
    .br_resolve_valid(br_resolve_valid),
    .br_actual_taken (br_actual_taken),
    .br_actual_target(br_actual_target),
    .br_resolve_type (br_resolve_type),
    .br_pred_taken   (br_pred_taken),
    .br_pred_target  (br_pred_target),
    .br_pred_hit     (br_pred_hit),
    .br_mispredict   (br_mispredict),
    .br_redirect_pc  (br_redirect_pc)
);

always #5 clk = ~clk;

task check_ok;
    input cond;
    input [255:0] msg;
    begin
        if (!cond) begin
            $display("tb_exec_pipe0_branch FAIL: %0s", msg);
            $finish(1);
        end
    end
endtask

task issue_branch;
    input [31:0] pc;
    input [31:0] imm;
    input [31:0] op_a;
    input [31:0] op_b;
    input        pred_taken;
    input [31:0] pred_target;
    input        pred_hit;
    input [1:0]  pred_type;
    begin
        @(negedge clk);
        in_valid       = 1'b1;
        in_pc          = pc;
        in_imm         = imm;
        in_op_a        = op_a;
        in_op_b        = op_b;
        in_pred_taken  = pred_taken;
        in_pred_target = pred_target;
        in_pred_hit    = pred_hit;
        in_pred_type   = pred_type;
        @(negedge clk);
        in_valid       = 1'b0;
    end
endtask

initial begin
    clk = 1'b0;
    rstn = 1'b0;
    in_valid = 1'b0;
    in_tag = 5'd3;
    in_pc = 32'h100;
    in_op_a = 32'd0;
    in_op_b = 32'd0;
    in_rs1_idx = 5'd0;
    in_imm = 32'd0;
    in_order_id = 16'd9;
    in_pred_taken = 1'b0;
    in_pred_target = 32'd0;
    in_pred_hit = 1'b0;
    in_pred_type = `BPU_TYPE_COND;
    in_func3 = `B_BEQ;
    in_func7 = 1'b0;
    in_alu_op = 3'b001;
    in_alu_src1 = `REG;
    in_alu_src2 = `REG;
    in_br_addr_mode = `B_PC;
    in_br = 1'b1;
    in_rd = 5'd0;
    in_regs_write = 1'b0;
    in_fu = `FU_INT0;
    in_tid = 1'b0;
    in_is_csr = 1'b0;
    in_is_mret = 1'b0;
    in_csr_addr = 12'd0;
    csr_rdata = 32'd0;

    repeat (3) @(negedge clk);
    rstn = 1'b1;

    issue_branch(32'h0000_0100, 32'h0000_0040, 32'h0000_0005, 32'h0000_0005, 1'b0, 32'd0, 1'b0, `BPU_TYPE_COND);
    @(negedge clk);
    check_ok(br_resolve_valid, "branch should resolve one cycle after issue");
    check_ok(br_actual_taken, "equal operands should make beq taken");
    check_ok(br_mispredict, "predicted NT but actual T should mispredict");
    check_ok(br_redirect_pc == 32'h0000_0140, "taken mispredict should redirect to target");
    check_ok(br_resolve_type == `BPU_TYPE_COND, "conditional branch should resolve as conditional");

    issue_branch(32'h0000_0200, 32'h0000_0020, 32'h0000_0001, 32'h0000_0002, 1'b1, 32'h0000_0220, 1'b1, `BPU_TYPE_COND);
    @(negedge clk);
    check_ok(br_resolve_valid, "second branch should resolve");
    check_ok(!br_actual_taken, "non-equal operands should make beq not-taken");
    check_ok(br_mispredict, "predicted T but actual NT should mispredict");
    check_ok(br_redirect_pc == 32'h0000_0204, "not-taken mispredict should redirect to pc+4");

    issue_branch(32'h0000_0300, 32'h0000_0030, 32'h0000_0007, 32'h0000_0007, 1'b1, 32'h0000_0330, 1'b1, `BPU_TYPE_COND);
    @(negedge clk);
    check_ok(br_resolve_valid, "third branch should resolve");
    check_ok(br_actual_taken, "third branch should be taken");
    check_ok(!br_mispredict, "matching taken prediction should not mispredict");
    check_ok(br_pred_taken, "predicted-taken sideband should be preserved");
    check_ok(br_pred_target == 32'h0000_0330, "predicted target sideband should be preserved");

    in_func3 = `I_JALR;
    in_alu_op = 3'b100;
    in_alu_src1 = `PC;
    in_alu_src2 = `PC_PLUS4;
    in_br_addr_mode = `J_REG;
    in_br = 1'b1;
    in_regs_write = 1'b1;
    issue_branch(32'h0000_0400, 32'h0000_0003, 32'h0000_0100, 32'd0, 1'b0, 32'd0, 1'b0, `BPU_TYPE_JALR);
    @(negedge clk);
    check_ok(br_resolve_valid, "jalr should resolve");
    check_ok(br_actual_taken, "jalr should always be taken");
    check_ok(br_resolve_type == `BPU_TYPE_JALR, "jalr should resolve as jalr");
    check_ok(br_actual_target == 32'h0000_0102, "jalr target must clear bit 0 per ISA");
    check_ok(br_redirect_pc == 32'h0000_0102, "jalr redirect target must clear bit 0");

    $display("tb_exec_pipe0_branch PASS");
    $finish;
end
endmodule
