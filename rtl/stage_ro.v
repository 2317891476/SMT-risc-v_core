module stage_ro(
    input  wire        clk,
    input  wire        rstn,
    // Read port
    input  wire [0:0]  ro_tid,         // thread_id of the instruction being read
    input  wire [4:0]  ro_rs1,
    input  wire [4:0]  ro_rs2,
    // Write port (from WB stage)
    input  wire [0:0]  w_thread_id,    // thread_id of the instruction writing back
    input  wire        w_regs_en,
    input  wire [4:0]  w_regs_addr,
    input  wire [31:0] w_regs_data,
    // Outputs
    output wire [31:0] ro_regs_data1,
    output wire [31:0] ro_regs_data2
);

regs_mt #(
    .N_T (2)
) u_regs_mt (
    .clk           (clk           ),
    .rstn          (rstn          ),
    .r_thread_id   (ro_tid        ),
    .r_regs_addr1  (ro_rs1        ),
    .r_regs_addr2  (ro_rs2        ),
    // Write port 0 - used by V1
    .w_thread_id_0 (w_thread_id   ),
    .w_regs_addr_0 (w_regs_addr   ),
    .w_regs_data_0 (w_regs_data   ),
    .w_regs_en_0   (w_regs_en     ),
    // Write port 1 - unused in V1 (tied off)
    .w_thread_id_1 (1'b0          ),
    .w_regs_addr_1 (5'd0          ),
    .w_regs_data_1 (32'd0         ),
    .w_regs_en_1   (1'b0          ),
    .r_regs_o1     (ro_regs_data1 ),
    .r_regs_o2     (ro_regs_data2 )
);

endmodule
