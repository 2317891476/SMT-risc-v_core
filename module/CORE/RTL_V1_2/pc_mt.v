// pc_mt.v
// Multi-Thread PC Manager (N_T=2 threads)
// Each thread maintains its own pc and pc_next.
// Output is the PC/TID of the thread selected by fetch_tid.

module pc_mt #(
    parameter N_T             = 2,
    parameter THREAD1_BOOT_PC = 32'h00000800  // Thread 1 boot address (default: word 512 in IROM)
)(
    input  wire          clk,
    input  wire          rstn,

    // Per-thread branch redirect
    input  wire [N_T-1:0] br_ctrl,          // [t] = branch taken for thread t
    input  wire [31:0]    br_addr_t0,       // branch target for thread 0
    input  wire [31:0]    br_addr_t1,       // branch target for thread 1

    // Per-thread stall / flush
    input  wire [N_T-1:0] pc_stall,         // [t] = stall PC of thread t
    input  wire [N_T-1:0] flush,            // [t] = flush (branch misprediction) for thread t

    // Thread scheduler selects which thread fetches this cycle
    input  wire [0:0]     fetch_tid,

    // Outputs: the PC and TID sent to IF stage
    output reg  [31:0]    if_pc,
    output reg  [0:0]     if_tid
);

reg [31:0] pc      [0:N_T-1];
reg [31:0] pc_next [0:N_T-1];

wire [31:0] br_addr [0:N_T-1];
assign br_addr[0] = br_addr_t0;
assign br_addr[1] = br_addr_t1;

integer t;

// -----------------------------------------------------------
// Per-thread PC update
// -----------------------------------------------------------
always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        pc[0]      <= 32'h00000000;
        pc_next[0] <= 32'h00000004;
        pc[1]      <= THREAD1_BOOT_PC;
        pc_next[1] <= THREAD1_BOOT_PC + 32'h4;
    end
    else begin
        for (t = 0; t < N_T; t = t + 1) begin
            if (br_ctrl[t]) begin
                pc[t]      <= br_addr[t];
                pc_next[t] <= br_addr[t] + 32'h4;
            end
            else if (pc_stall[t]) begin
                // hold
                pc[t]      <= pc[t];
                pc_next[t] <= pc_next[t];
            end
            else if (fetch_tid == t[0:0]) begin
                // Only advance PC when this thread is the one fetching
                pc[t]      <= pc_next[t];
                pc_next[t] <= pc_next[t] + 32'h4;
            end
            // else: not selected this cycle, hold
        end
    end
end

// -----------------------------------------------------------
// Output: combinatorial mux on fetch_tid
// -----------------------------------------------------------
always @(*) begin
    if_pc  = pc[fetch_tid];
    if_tid = fetch_tid;
end

endmodule
