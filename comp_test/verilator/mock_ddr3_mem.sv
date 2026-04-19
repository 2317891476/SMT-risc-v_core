`timescale 1ns/1ps

module mock_ddr3_mem #(
    parameter integer MEM_WORDS = 262144,
    parameter [31:0]  BASE_ADDR = 32'h00000000,
    parameter integer DEFAULT_LATENCY = 1
) (
    input  wire        clk,
    input  wire        rstn,
    input  wire        req_valid,
    output wire        req_ready,
    input  wire [31:0] req_addr,
    input  wire        req_write,
    input  wire [31:0] req_wdata,
    input  wire [3:0]  req_wen,
    output reg         resp_valid,
    output reg [31:0]  resp_data,
    output wire        init_calib_complete,
    output reg [31:0]  debug_read_count,
    output reg [31:0]  debug_write_count,
    output reg [31:0]  debug_last_read_addr,
    output reg [31:0]  debug_last_write_addr,
    output reg [31:0]  debug_last_write_data,
    output reg [31:0]  debug_range_error_count,
    output reg [31:0]  debug_last_range_error_addr,
    output reg [31:0]  debug_uninit_read_count
);

    reg [31:0] mem [0:MEM_WORDS-1] /* verilator public_flat_rw */;
    reg        init_calib_complete_r;
    reg        pending_valid_r;
    reg [31:0] pending_cycles_r;
    reg [31:0] pending_resp_data_r;

    integer init_idx;
    integer preload_latency_cfg;
    reg [1023:0] preload_hex;

    wire [31:0] word_offset_w = req_addr - BASE_ADDR;
    wire        addr_in_range_w = (req_addr >= BASE_ADDR) && (word_offset_w[31:2] < MEM_WORDS);
    wire [31:0] word_index_w = word_offset_w[31:2];

    function automatic [31:0] apply_wen_word(
        input [31:0] old_word,
        input [31:0] new_word,
        input [3:0]  wen
    );
        reg [31:0] tmp;
        begin
            tmp = old_word;
            if (wen[0]) tmp[7:0]   = new_word[7:0];
            if (wen[1]) tmp[15:8]  = new_word[15:8];
            if (wen[2]) tmp[23:16] = new_word[23:16];
            if (wen[3]) tmp[31:24] = new_word[31:24];
            apply_wen_word = tmp;
        end
    endfunction

    assign req_ready = rstn && !pending_valid_r && !resp_valid;
    assign init_calib_complete = init_calib_complete_r;

    initial begin
        preload_latency_cfg = DEFAULT_LATENCY;
        if ($value$plusargs("MOCK_DDR3_FORCE_LATENCY=%d", preload_latency_cfg)) begin
            if (preload_latency_cfg < 1)
                preload_latency_cfg = 1;
        end
        for (init_idx = 0; init_idx < MEM_WORDS; init_idx = init_idx + 1) begin
            mem[init_idx] = 32'h00000000;
        end
        if ($value$plusargs("MOCK_DDR3_PRELOAD_HEX=%s", preload_hex)) begin
            $readmemh(preload_hex, mem);
        end
    end

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            init_calib_complete_r <= 1'b0;
            resp_valid            <= 1'b0;
            resp_data             <= 32'd0;
            pending_valid_r       <= 1'b0;
            pending_cycles_r      <= 32'd0;
            pending_resp_data_r   <= 32'd0;
            debug_read_count      <= 32'd0;
            debug_write_count     <= 32'd0;
            debug_last_read_addr  <= 32'd0;
            debug_last_write_addr <= 32'd0;
            debug_last_write_data <= 32'd0;
            debug_range_error_count <= 32'd0;
            debug_last_range_error_addr <= 32'd0;
            debug_uninit_read_count <= 32'd0;
        end else begin
            init_calib_complete_r <= 1'b1;
            resp_valid <= 1'b0;

            if (pending_valid_r) begin
                if (pending_cycles_r == 32'd0) begin
                    resp_valid      <= 1'b1;
                    resp_data       <= pending_resp_data_r;
                    pending_valid_r <= 1'b0;
                end else begin
                    pending_cycles_r <= pending_cycles_r - 32'd1;
                end
            end

            if (req_valid && req_ready) begin
                pending_valid_r  <= 1'b1;
                pending_cycles_r <= preload_latency_cfg - 1;

                if (!addr_in_range_w) begin
                    pending_resp_data_r    <= 32'd0;
                    debug_range_error_count <= debug_range_error_count + 32'd1;
                    debug_last_range_error_addr <= req_addr;
                end else if (req_write) begin
                    mem[word_index_w]      <= apply_wen_word(mem[word_index_w], req_wdata, req_wen);
                    pending_resp_data_r    <= 32'd0;
                    debug_write_count      <= debug_write_count + 32'd1;
                    debug_last_write_addr  <= req_addr;
                    debug_last_write_data  <= req_wdata;
                end else begin
                    pending_resp_data_r   <= mem[word_index_w];
                    debug_read_count      <= debug_read_count + 32'd1;
                    debug_last_read_addr  <= req_addr;
                    if (mem[word_index_w] === 32'h00000000)
                        debug_uninit_read_count <= debug_uninit_read_count + 32'd1;
                end
            end
        end
    end

endmodule
