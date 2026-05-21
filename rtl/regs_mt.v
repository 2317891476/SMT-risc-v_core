// regs_mt.v
// Single-Thread Register File (32 x 32-bit)
// Read port reads from the single bank.
// Write port writes to the single bank.
// Same-cycle WB hazard bypass is included.

module regs_mt(
    input  wire        clk,
    input  wire        rstn,

    // Read port
    input  wire [4:0]  r_regs_addr1,
    input  wire [4:0]  r_regs_addr2,

    // Write port 0 (from WB stage Pipe 0)
    input  wire [4:0]  w_regs_addr_0,
    input  wire [31:0] w_regs_data_0,
    input  wire        w_regs_en_0,

    // Write port 1 (from WB stage Pipe 1)
    input  wire [4:0]  w_regs_addr_1,
    input  wire [31:0] w_regs_data_1,
    input  wire        w_regs_en_1,

    output wire [31:0] r_regs_o1,
    output wire [31:0] r_regs_o2
);

reg [31:0] reg_bank [0:31];

integer i;

// Dual Write ports (Port 1 takes priority if both write same register)
always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        for (i = 0; i < 32; i = i + 1) begin
            reg_bank[i] <= 32'd0;
        end
    end
    else begin
        // Write port 0
        if (w_regs_en_0 && (w_regs_addr_0 != 5'd0)) begin
            `ifdef VERBOSE_SIM_LOGS
            $display("WRITE x%0d = %h (port0)", w_regs_addr_0, w_regs_data_0);
            `endif
            reg_bank[w_regs_addr_0] <= w_regs_data_0;
        end
        // Write port 1 (can override port 0 if same address)
        if (w_regs_en_1 && (w_regs_addr_1 != 5'd0)) begin
            `ifdef VERBOSE_SIM_LOGS
            $display("WRITE x%0d = %h (port1)", w_regs_addr_1, w_regs_data_1);
            `endif
            reg_bank[w_regs_addr_1] <= w_regs_data_1;
        end
    end
end

// Read with WB-same-cycle forwarding (both ports, port 1 takes priority)
wire wb0_hazard_a = w_regs_en_0 &&
                    (w_regs_addr_0 != 5'd0) &&
                    (w_regs_addr_0 == r_regs_addr1);

wire wb0_hazard_b = w_regs_en_0 &&
                    (w_regs_addr_0 != 5'd0) &&
                    (w_regs_addr_0 == r_regs_addr2);

wire wb1_hazard_a = w_regs_en_1 &&
                    (w_regs_addr_1 != 5'd0) &&
                    (w_regs_addr_1 == r_regs_addr1);

wire wb1_hazard_b = w_regs_en_1 &&
                    (w_regs_addr_1 != 5'd0) &&
                    (w_regs_addr_1 == r_regs_addr2);

// Port 1 takes priority for forwarding
assign r_regs_o1 = wb1_hazard_a ? w_regs_data_1 :
                   wb0_hazard_a ? w_regs_data_0 :
                   reg_bank[r_regs_addr1];

assign r_regs_o2 = wb1_hazard_b ? w_regs_data_1 :
                   wb0_hazard_b ? w_regs_data_0 :
                   reg_bank[r_regs_addr2];

endmodule
