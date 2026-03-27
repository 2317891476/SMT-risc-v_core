// =============================================================================
// Module : inst_memory
// Description: Simple instruction memory for V1 architecture.
//   - Wraps inst_backing_store for direct instruction fetch
//   - Synchronous read interface compatible with V1 stage_if
//   - Preserved hierarchy: u_inst_memory.u_inst_backing_store.u_ram
// =============================================================================
module inst_memory #(
    parameter IROM_SPACE = 4096
)(
    input  wire       clk,
    input  wire       rstn,
    input  wire [31:0] inst_addr,
    output wire [31:0] inst_o
);

// Backing Store - provides instruction data
// Preserved hierarchy for testbench compatibility
inst_backing_store #(
    .IROM_SPACE (IROM_SPACE)
) u_inst_backing_store (
    .clk       (clk      ),
    .rstn      (rstn     ),
    .inst_addr (inst_addr),
    .inst_o    (inst_o   )
);

endmodule
