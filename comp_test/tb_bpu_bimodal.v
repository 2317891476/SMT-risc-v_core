`timescale 1ns/1ps
`include "../rtl/define.v"

module tb_bpu_bimodal;
reg         clk;
reg         rstn;
reg  [31:0] pred_pc;
reg  [0:0]  pred_tid;
wire        pred_taken;
wire [31:0] pred_target;
wire        pred_hit;
wire [1:0]  pred_type;
reg         resolve_valid;
reg  [31:0] resolve_pc;
reg  [0:0]  resolve_tid;
reg         resolve_taken;
reg  [31:0] resolve_target;
reg  [1:0]  resolve_type;

bpu_bimodal dut (
    .clk           (clk),
    .rstn          (rstn),
    .pred_pc       (pred_pc),
    .pred_tid      (pred_tid),
    .pred_taken    (pred_taken),
    .pred_target   (pred_target),
    .pred_hit      (pred_hit),
    .pred_type     (pred_type),
    .resolve_valid (resolve_valid),
    .resolve_pc    (resolve_pc),
    .resolve_tid   (resolve_tid),
    .resolve_taken (resolve_taken),
    .resolve_target(resolve_target),
    .resolve_type  (resolve_type)
);

always #5 clk = ~clk;

task check_ok;
    input cond;
    input [255:0] msg;
    begin
        if (!cond) begin
            $display("tb_bpu_bimodal FAIL: %0s", msg);
            $finish(1);
        end
    end
endtask

task do_resolve;
    input [31:0] pc;
    input [0:0]  tid;
    input        taken;
    input [31:0] target;
    input [1:0]  typ;
    begin
        @(negedge clk);
        resolve_valid  = 1'b1;
        resolve_pc     = pc;
        resolve_tid    = tid;
        resolve_taken  = taken;
        resolve_target = target;
        resolve_type   = typ;
        @(negedge clk);
        resolve_valid  = 1'b0;
    end
endtask

initial begin
    clk = 1'b0;
    rstn = 1'b0;
    pred_pc = 32'h0000_0100;
    pred_tid = 1'b0;
    resolve_valid = 1'b0;
    resolve_pc = 32'd0;
    resolve_tid = 1'b0;
    resolve_taken = 1'b0;
    resolve_target = 32'd0;
    resolve_type = `BPU_TYPE_COND;

    repeat (3) @(negedge clk);
    rstn = 1'b1;
    @(negedge clk);

    check_ok(!pred_hit, "fresh predictor should miss");
    check_ok(!pred_taken, "fresh predictor should default not-taken");

    do_resolve(32'h0000_0100, 1'b0, 1'b1, 32'h0000_0140, `BPU_TYPE_COND);
    pred_pc = 32'h0000_0100;
    @(negedge clk);
    check_ok(pred_hit, "trained conditional branch should hit in BTB");
    check_ok(pred_taken, "taken training should move conditional branch to predict taken");
    check_ok(pred_target == 32'h0000_0140, "trained target should be returned");
    check_ok(pred_type == `BPU_TYPE_COND, "conditional branch type should be preserved");

    do_resolve(32'h0000_0100, 1'b0, 1'b0, 32'h0000_0140, `BPU_TYPE_COND);
    do_resolve(32'h0000_0100, 1'b0, 1'b0, 32'h0000_0140, `BPU_TYPE_COND);
    pred_pc = 32'h0000_0100;
    @(negedge clk);
    check_ok(pred_hit, "conditional branch should retain BTB entry after not-taken training");
    check_ok(!pred_taken, "two not-taken updates should drive prediction back to not-taken");

    do_resolve(32'h0000_0200, 1'b0, 1'b1, 32'h0000_0300, `BPU_TYPE_JAL);
    pred_pc = 32'h0000_0200;
    @(negedge clk);
    check_ok(pred_hit, "jal should populate BTB");
    check_ok(pred_taken, "jal should predict taken on BTB hit");
    check_ok(pred_type == `BPU_TYPE_JAL, "jal entry type should be preserved");
    check_ok(pred_target == 32'h0000_0300, "jal target should be returned");

    do_resolve(32'h0000_0500, 1'b0, 1'b1, 32'h0000_0540, `BPU_TYPE_COND);
    pred_pc = 32'h0000_0900; // same index as 0x100/0x500 with a different tag
    @(negedge clk);
    check_ok(!pred_hit, "BTB tag mismatch should prevent alias hit");
    check_ok(!pred_taken, "BTB tag mismatch should fall back to not-taken");

    do_resolve(32'h0000_0100, 1'b0, 1'b1, 32'h0000_0110, `BPU_TYPE_COND);
    pred_pc = 32'h0000_0104; // same BTB index after tid xor, same PC tag window
    pred_tid = 1'b1;
    @(negedge clk);
    check_ok(!pred_hit, "BTB entries must not alias across threads");
    check_ok(!pred_taken, "cross-thread alias must not predict taken");

    $display("tb_bpu_bimodal PASS");
    $finish;
end
endmodule
