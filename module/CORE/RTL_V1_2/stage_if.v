module stage_if(
    input  wire          clk,
    input  wire          rstn,
    // stall / flush is global (simplified: single stall bus)
    input  wire          pc_stall,
    input  wire [1:0]    if_flush,      // [t] = flush thread t
    // Per-thread branch redirect from EX stage
    input  wire [31:0]   br_addr_t0,
    input  wire [31:0]   br_addr_t1,
    input  wire [1:0]    br_ctrl,       // [t] = branch taken for thread t
    // Thread scheduler
    input  wire [0:0]    fetch_tid,
    // Outputs to IF/ID register
    output wire [31:0]   if_inst,
    output wire [31:0]   if_pc,
    output wire [0:0]    if_tid
);

pc_mt #(
    .N_T             (2             ),
    .THREAD1_BOOT_PC (32'h00000800  )
) u_pc_mt (
    .clk         (clk          ),
    .rstn        (rstn         ),
    .br_ctrl     (br_ctrl      ),
    .br_addr_t0  (br_addr_t0   ),
    .br_addr_t1  (br_addr_t1   ),
    .pc_stall    ({pc_stall, pc_stall}),  // simplified: same stall for both threads
    .flush       (if_flush     ),
    .fetch_tid   (fetch_tid    ),
    .if_pc       (if_pc        ),
    .if_tid      (if_tid       )
);

inst_memory #(
    .IROM_SPACE (4096)
) u_inst_memory (
    .clk       (clk                             ),
    .rstn      (rstn && !(if_flush[fetch_tid])  ),
    .inst_addr (if_pc                           ),
    .inst_o    (if_inst                         )
);


endmodule