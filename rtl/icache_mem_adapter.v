// =============================================================================
// Module : icache_mem_adapter
// Description: Adapter between icache (burst interface) and inst_backing_store.
//   - Converts icache line fill requests to sequential word reads
//   - Provides AXI-like burst interface over single-ported backing store
// =============================================================================
module icache_mem_adapter #(
    parameter ADDR_WIDTH = 32,
    parameter LINE_SIZE  = 32,        // Bytes per cache line
    parameter IROM_SPACE = 4096       // Total instruction memory space
)(
    input  wire                     clk,
    input  wire                     rstn,

    // ─── ICache Request Interface ───────────────────────────────
    input  wire                     req_valid,
    output reg                      req_ready,
    input  wire [ADDR_WIDTH-1:0]    req_addr,       // Line-aligned address

    // ─── ICache Response Interface ──────────────────────────────
    output reg                      resp_valid,
    output reg  [31:0]              resp_data,
    output reg                      resp_last,
    input  wire                     resp_ready,

    // ─── Backing Store Interface ────────────────────────────────
    output reg  [31:0]              mem_addr,
    input  wire [31:0]              mem_data        // Combinational read
);

localparam WORDS_PER_LINE = LINE_SIZE / 4;
localparam WORD_CNT_W     = $clog2(WORDS_PER_LINE);

// State machine
localparam S_IDLE = 1'b0;
localparam S_BURST = 1'b1;

reg state;
reg [WORD_CNT_W:0] word_cnt;
reg [ADDR_WIDTH-1:0] burst_base_addr;

wire [WORD_CNT_W-1:0] current_word_idx = word_cnt[WORD_CNT_W-1:0];
wire [ADDR_WIDTH-1:0] current_addr = burst_base_addr + (current_word_idx * 4);

// Backing store address is word-addressed
wire [ADDR_WIDTH-1:0] mem_word_addr = current_addr;

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        state           <= S_IDLE;
        req_ready       <= 1'b1;
        resp_valid      <= 1'b0;
        resp_data       <= 32'd0;
        resp_last       <= 1'b0;
        word_cnt        <= 0;
        burst_base_addr <= {ADDR_WIDTH{1'b0}};
    end
    else begin
        case (state)
            S_IDLE: begin
                resp_valid <= 1'b0;
                resp_last  <= 1'b0;
                
                if (req_valid && req_ready) begin
                    // Start burst
                    burst_base_addr <= req_addr;
                    word_cnt        <= 0;
                    req_ready       <= 1'b0;
                    state           <= S_BURST;
                end
            end
            
            S_BURST: begin
                // Output current word
                mem_addr   <= current_addr;
                resp_data  <= mem_data;
                resp_valid <= 1'b1;
                resp_last  <= (current_word_idx == WORDS_PER_LINE - 1);
                
                if (resp_ready) begin
                    if (current_word_idx == WORDS_PER_LINE - 1) begin
                        // Burst complete
                        state     <= S_IDLE;
                        req_ready <= 1'b1;
                    end
                    else begin
                        word_cnt <= word_cnt + 1;
                    end
                end
            end
        endcase
    end
end

endmodule
