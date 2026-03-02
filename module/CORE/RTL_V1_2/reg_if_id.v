module reg_if_id(
    input wire clk,
    input wire rstn,
    input wire[31:0] if_pc,
    input wire[31:0] if_inst,
    input wire[0:0]  if_tid,
    output wire[31:0] id_inst,
    output reg[31:0]  id_pc,
    output reg[0:0]   id_tid,
    //hazard detection
    input  wire if_id_flush,
    input  wire if_id_stall
);

reg [31:0]     id_inst_reg;
reg            inst_swift; // when stall/flush, hold previous fetched instruction

always @(posedge clk  or negedge rstn) begin
    if (!rstn)begin
        inst_swift  <= 1'b0;
    end
    else if (if_id_stall || if_id_flush) begin
        inst_swift  <= 1'b1;
    end
    else begin
        inst_swift  <= 1'b0;
    end
end

always @(posedge clk  or negedge rstn) begin
    if ((!rstn) || if_id_flush)begin
        id_pc  <= 32'b0;
        id_tid <= 1'b0;
    end
    else if (if_id_stall) begin
        id_pc  <= id_pc;
        id_tid <= id_tid;
    end
    else begin
        id_pc  <= if_pc;
        id_tid <= if_tid;
    end
end

always @(posedge clk  or negedge rstn) begin
    if ((!rstn) || if_id_flush)begin
        id_inst_reg <= 32'b0;
    end
    else if (if_id_stall && !inst_swift) begin
        // latch once when entering stall so IF/ID holds a stable instruction
        id_inst_reg <= if_inst;
    end
    else if (!if_id_stall) begin
        id_inst_reg <= if_inst;
        $display("id_inst: %h",id_inst );        
    end
end

assign id_inst = (inst_swift)? id_inst_reg : if_inst;


endmodule
