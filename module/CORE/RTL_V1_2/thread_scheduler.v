// thread_scheduler.v
// SMT Round-Robin thread fetch scheduler
// Selects which thread to fetch from each cycle.
// If the selected thread is stalled (RS full), tries the other.

module thread_scheduler(
    input  wire       clk,
    input  wire       rstn,
    // Per-thread stall requests (e.g. RS full)
    input  wire [1:0] thread_stall,   // [0]=T0 stall, [1]=T1 stall
    // Which thread to fetch this cycle
    output reg  [0:0] fetch_tid
);

reg [0:0] rr_next; // next round-robin candidate

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        fetch_tid <= 1'b0;
        rr_next   <= 1'b1;
    end
    else begin
        // Advance round-robin pointer
        rr_next <= ~rr_next;

        if (!thread_stall[rr_next]) begin
            // Preferred candidate is free — use it
            fetch_tid <= rr_next;
        end
        else if (!thread_stall[~rr_next]) begin
            // Preferred is stalled, other is free — use other
            fetch_tid <= ~rr_next;
        end
        else begin
            // Both stalled — keep current (frontend will stall anyway)
            fetch_tid <= fetch_tid;
        end
    end
end

endmodule
