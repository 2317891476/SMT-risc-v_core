`include "define.v"
//=================================================================================
// Module: inst_backing_store
// Description: Stable instruction backing-store wrapper for bench preload
//              
// This module provides a STABLE HIERARCHY for testbench preloading that is
// independent of the internal implementation details of the instruction fetch
// path. Testbenches should reference:
//      tb_mod.u_inst_backing_store.u_ram.mem[]
//
// This allows the fetch path (inst_memory, ICache, etc.) to evolve without
// breaking bench preload compatibility.
//
// Created for: Task 3 - Preserve bench preload compatibility
//=================================================================================

module inst_backing_store #(
    parameter IROM_SPACE = 4096
)(
    input  wire       clk,
    input  wire       rstn,
    input  wire[31:0] inst_addr,
    output wire[31:0] inst_o
);

localparam ADDR_WIDTH = $clog2(IROM_SPACE);
wire [ADDR_WIDTH -1 : 0] inst_addr_2;

assign inst_addr_2 = inst_addr[ADDR_WIDTH +2-1 : 2];

`ifdef FPGA_MODE
(* ram_style = "block" *) reg [31:0] mem [0:IROM_SPACE-1];
reg [31:0] inst_o_r;

initial begin
    $readmemh("inst.hex", mem);
end

always @(posedge clk or negedge rstn) begin
    if (!rstn)
        inst_o_r <= 32'd0;
    else
        inst_o_r <= mem[inst_addr_2];
end

assign inst_o = inst_o_r;
`else
// The stable RAM instance - benches should poke this directly
ram_bfm #(
    .DATA_WHITH     ( 32            ),
    .DATA_SIZE      ( 8             ),
    .ADDR_WHITH     ( ADDR_WIDTH    ),
    .RAM_DEPTH      ( IROM_SPACE    )
)
u_ram(
    //system signals
    .clk                        ( clk               ),
    //RAM Control signals
    .cs                         ( rstn              ), //Once the reset is canceled, the memory starts outputting instructions
    .we                         ( 4'b0              ),
    .addr                       ( inst_addr_2       ),
    .wdata                      ( 32'b0             ),
    .rdata                      ( inst_o            )
);
`endif

endmodule
