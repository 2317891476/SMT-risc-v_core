// regs_mt.v
// Multi-Thread Register File (N_T=2 banks, 32 x 32-bit each)
// Read port uses r_thread_id to select bank.
// Write port uses w_thread_id to select bank.
// Same-cycle WB hazard bypass is scoped to the same thread.

module regs_mt #(

    parameter N_T = 2

)(

    input  wire        clk,

    input  wire        rstn,



    // Read port

    input  wire [0:0]  r_thread_id,

    input  wire [4:0]  r_regs_addr1,

    input  wire [4:0]  r_regs_addr2,



    // Write port 0 (from WB stage Pipe 0)

    input  wire [0:0]  w_thread_id_0,

    input  wire [4:0]  w_regs_addr_0,

    input  wire [31:0] w_regs_data_0,

    input  wire        w_regs_en_0,



    // Write port 1 (from WB stage Pipe 1)

    input  wire [0:0]  w_thread_id_1,

    input  wire [4:0]  w_regs_addr_1,

    input  wire [31:0] w_regs_data_1,

    input  wire        w_regs_en_1,



    output wire [31:0]   r_regs_o1,

    output wire [31:0]   r_regs_o2

);



// Two banks of 32 registers

reg [31:0] reg_bank [0:N_T-1][0:31];



integer i, b;



// -----------------------------------------------------------

// Dual Write ports (Port 1 takes priority if both write same register)

// -----------------------------------------------------------

always @(posedge clk or negedge rstn) begin

    if (!rstn) begin

        for (b = 0; b < N_T; b = b + 1) begin

            for (i = 0; i < 32; i = i + 1) begin

                reg_bank[b][i] <= 32'd0;

            end

        end

    end

    else begin

        // Write port 0

        if (w_regs_en_0 && (w_regs_addr_0 != 5'd0)) begin

            `ifndef SYNTHESIS

            $display("WRITE T%0d x%0d = %h (port0)", w_thread_id_0, w_regs_addr_0, w_regs_data_0);

            `endif

            reg_bank[w_thread_id_0][w_regs_addr_0] <= w_regs_data_0;

        end

        // Write port 1 (can override port 0 if same address)

        if (w_regs_en_1 && (w_regs_addr_1 != 5'd0)) begin

            `ifndef SYNTHESIS

            $display("WRITE T%0d x%0d = %h (port1)", w_thread_id_1, w_regs_addr_1, w_regs_data_1);

            `endif

            reg_bank[w_thread_id_1][w_regs_addr_1] <= w_regs_data_1;

        end

    end

end



// -----------------------------------------------------------

// Read with WB-same-cycle forwarding (both ports, port 1 takes priority)

// -----------------------------------------------------------

wire wb0_hazard_a = w_regs_en_0 &&

                    (w_regs_addr_0 != 5'd0) &&

                    (w_regs_addr_0 == r_regs_addr1) &&

                    (w_thread_id_0 == r_thread_id);



wire wb0_hazard_b = w_regs_en_0 &&

                    (w_regs_addr_0 != 5'd0) &&

                    (w_regs_addr_0 == r_regs_addr2) &&

                    (w_thread_id_0 == r_thread_id);



wire wb1_hazard_a = w_regs_en_1 &&

                    (w_regs_addr_1 != 5'd0) &&

                    (w_regs_addr_1 == r_regs_addr1) &&

                    (w_thread_id_1 == r_thread_id);



wire wb1_hazard_b = w_regs_en_1 &&

                    (w_regs_addr_1 != 5'd0) &&

                    (w_regs_addr_1 == r_regs_addr2) &&

                    (w_thread_id_1 == r_thread_id);



// Port 1 takes priority for forwarding

assign r_regs_o1 = wb1_hazard_a ? w_regs_data_1 :

                   wb0_hazard_a ? w_regs_data_0 :

                   reg_bank[r_thread_id][r_regs_addr1];



assign r_regs_o2 = wb1_hazard_b ? w_regs_data_1 :

                   wb0_hazard_b ? w_regs_data_0 :

                   reg_bank[r_thread_id][r_regs_addr2];



endmodule
