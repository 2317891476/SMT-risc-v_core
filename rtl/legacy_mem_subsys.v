`include "define.v"

module legacy_mem_subsys #(
    parameter RAM_WORDS = 4096
) (
    input  wire        clk,
    input  wire        rstn,
    input  wire        uart_rx,

    input  wire [31:0] load_addr,
    input  wire [3:0]  load_read,
    output reg  [31:0] load_rdata,

    input  wire        sb_write_valid,
    input  wire [31:0] sb_write_addr,
    input  wire [31:0] sb_write_data,
    input  wire [3:0]  sb_write_wen,
    output wire        sb_write_ready,

    output reg  [7:0]  tube_status,
    output wire        uart_tx,
    output wire        debug_uart_status_busy,
    output wire        debug_uart_busy,
    output wire        debug_uart_pending_valid,
    output reg  [7:0]  debug_uart_status_load_count,
    output reg  [7:0]  debug_uart_tx_store_count,
    output reg         debug_uart_tx_byte_valid,
    output reg  [7:0]  debug_uart_tx_byte
);

localparam RAM_ADDR_W = $clog2(RAM_WORDS);
`ifdef FPGA_MODE
    `ifndef FPGA_UART_CLK_DIV
        `define FPGA_UART_CLK_DIV 174
    `endif
localparam integer UART_CLK_DIV = `FPGA_UART_CLK_DIV;
`else
// Keep simulation fast while preserving board behavior in FPGA builds.
localparam integer UART_CLK_DIV = 4;
`endif

(* ram_style = "block" *) reg [31:0] data_mem [0:RAM_WORDS-1];
reg        uart_tx_start_r;
reg [7:0]  uart_tx_data_r;
reg        uart_pending_valid_r;
reg [7:0]  uart_pending_byte_r;
reg        uart_tx_enable_r;
reg        uart_rx_enable_r;
reg        uart_rx_valid_r;
reg        uart_rx_overrun_r;
reg        uart_rx_frame_err_r;
reg [7:0]  uart_rx_data_r;
wire       uart_busy;
wire       uart_status_busy;
wire       uart_rx_byte_valid;
wire [7:0] uart_rx_byte;
wire       uart_rx_frame_error;

wire load_req = |load_read;
wire load_addr_is_ram = (load_addr >= `RAM_CACHEABLE_BASE) && (load_addr <= `RAM_CACHEABLE_TOP);
wire load_addr_is_tube = (load_addr == `TUBE_ADDR);
wire load_addr_is_uart_status = (load_addr == `UART_STATUS_ADDR);
wire load_addr_is_uart_rx = (load_addr == `UART_RXDATA_ADDR);
wire load_addr_is_uart_ctrl = (load_addr == `UART_CTRL_ADDR);
wire sb_addr_is_ram = (sb_write_addr >= `RAM_CACHEABLE_BASE) && (sb_write_addr <= `RAM_CACHEABLE_TOP);
wire sb_addr_is_tube = (sb_write_addr == `TUBE_ADDR);
wire sb_addr_is_uart_tx = (sb_write_addr == `UART_TXDATA_ADDR);
wire sb_addr_is_uart_ctrl = (sb_write_addr == `UART_CTRL_ADDR);

wire [RAM_ADDR_W-1:0] load_word_idx = load_addr[RAM_ADDR_W+1:2];
wire [RAM_ADDR_W-1:0] sb_word_idx = sb_write_addr[RAM_ADDR_W+1:2];
wire [7:0] uart_write_byte = select_mmio_byte(8'd0, sb_write_data, sb_write_wen);
wire uart_store_accept = sb_write_valid && sb_addr_is_uart_tx && uart_tx_enable_r && !uart_pending_valid_r;
wire uart_write_fire = uart_store_accept;
wire [7:0] uart_ctrl_write_byte = select_mmio_byte(8'd0, sb_write_data, sb_write_wen);
wire uart_ctrl_write = sb_write_valid && sb_addr_is_uart_ctrl;
wire uart_rx_pop = load_req && load_addr_is_uart_rx;
assign uart_status_busy = uart_busy || uart_pending_valid_r || uart_tx_start_r;
assign debug_uart_status_busy = uart_status_busy;
assign debug_uart_busy = uart_busy;
assign debug_uart_pending_valid = uart_pending_valid_r;
wire [31:0] uart_status_word = {
    25'd0,
    uart_tx_enable_r,
    uart_rx_enable_r,
    uart_rx_frame_err_r,
    uart_rx_overrun_r,
    uart_rx_valid_r,
    (~uart_status_busy && uart_tx_enable_r),
    uart_status_busy
};
wire [31:0] uart_ctrl_word = {29'd0, uart_rx_valid_r, uart_rx_enable_r, uart_tx_enable_r};

assign sb_write_ready =
    !sb_write_valid ? 1'b1 :
    sb_addr_is_uart_tx ? (uart_tx_enable_r && !uart_pending_valid_r) :
    sb_addr_is_uart_ctrl ? 1'b1 :
    sb_addr_is_tube ? 1'b1 :
    sb_addr_is_ram ? !load_req :
    !load_req;

function [31:0] merge_write_data;
    input [31:0] old_word;
    input [31:0] new_word;
    input [3:0]  byte_en;
    begin
        merge_write_data = old_word;
        if (byte_en[0]) merge_write_data[7:0]   = new_word[7:0];
        if (byte_en[1]) merge_write_data[15:8]  = new_word[15:8];
        if (byte_en[2]) merge_write_data[23:16] = new_word[23:16];
        if (byte_en[3]) merge_write_data[31:24] = new_word[31:24];
    end
endfunction

function [7:0] select_mmio_byte;
    input [7:0] current_value;
    input [31:0] new_word;
    input [3:0]  byte_en;
    begin
        select_mmio_byte = current_value;
        if (byte_en[0]) select_mmio_byte = new_word[7:0];
        else if (byte_en[1]) select_mmio_byte = new_word[15:8];
        else if (byte_en[2]) select_mmio_byte = new_word[23:16];
        else if (byte_en[3]) select_mmio_byte = new_word[31:24];
    end
endfunction

integer idx;
initial begin
    for (idx = 0; idx < RAM_WORDS; idx = idx + 1) begin
        data_mem[idx] = 32'd0;
    end
`ifdef FPGA_MODE
    $readmemh("data_word.hex", data_mem);
`endif
end

uart_tx #(
    .CLK_DIV(UART_CLK_DIV)
) u_uart_tx (
    .clk      (clk            ),
    .rst_n    (rstn           ),
    .tx_start (uart_tx_start_r),
    .tx_data  (uart_tx_data_r ),
    .tx       (uart_tx        ),
    .busy     (uart_busy      )
);

uart_rx #(
    .CLK_DIV(UART_CLK_DIV)
) u_uart_rx (
    .clk         (clk                ),
    .rst_n       (rstn               ),
    .enable      (uart_rx_enable_r   ),
    .rx          (uart_rx            ),
    .byte_valid  (uart_rx_byte_valid ),
    .byte_data   (uart_rx_byte       ),
    .frame_error (uart_rx_frame_error)
);

always @(posedge clk) begin
    if (!load_req && sb_write_valid && sb_addr_is_ram) begin
        data_mem[sb_word_idx] <= merge_write_data(data_mem[sb_word_idx], sb_write_data, sb_write_wen);
    end
end

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        uart_tx_start_r     <= 1'b0;
        uart_tx_data_r      <= 8'd0;
        uart_pending_valid_r <= 1'b0;
        uart_pending_byte_r  <= 8'd0;
        uart_tx_enable_r     <= 1'b1;
        uart_rx_enable_r     <= 1'b1;
        uart_rx_valid_r      <= 1'b0;
        uart_rx_overrun_r    <= 1'b0;
        uart_rx_frame_err_r  <= 1'b0;
        uart_rx_data_r       <= 8'd0;
        debug_uart_tx_store_count <= 8'd0;
        debug_uart_tx_byte_valid  <= 1'b0;
        debug_uart_tx_byte        <= 8'd0;
    end else begin
        uart_tx_start_r <= 1'b0;
        debug_uart_tx_byte_valid <= 1'b0;

        if (uart_store_accept) begin
            uart_pending_byte_r  <= uart_write_byte;
            uart_pending_valid_r <= 1'b1;
            debug_uart_tx_store_count <= debug_uart_tx_store_count + 8'd1;
            debug_uart_tx_byte_valid  <= 1'b1;
            debug_uart_tx_byte        <= uart_write_byte;
        end

        if (uart_pending_valid_r && !uart_busy) begin
            uart_tx_data_r       <= uart_pending_byte_r;
            uart_tx_start_r      <= 1'b1;
            uart_pending_valid_r <= 1'b0;
        end

        if (uart_ctrl_write) begin
            uart_tx_enable_r <= uart_ctrl_write_byte[0];
            uart_rx_enable_r <= uart_ctrl_write_byte[1];
            if (uart_ctrl_write_byte[2]) begin
                uart_rx_overrun_r <= 1'b0;
            end
            if (uart_ctrl_write_byte[3]) begin
                uart_rx_frame_err_r <= 1'b0;
            end
            if (!uart_ctrl_write_byte[1] || uart_ctrl_write_byte[4]) begin
                uart_rx_valid_r <= 1'b0;
            end
        end

        if (uart_rx_pop) begin
            uart_rx_valid_r <= 1'b0;
        end

        if (uart_rx_frame_error) begin
            uart_rx_frame_err_r <= 1'b1;
        end

        if (uart_rx_byte_valid) begin
            if (uart_rx_valid_r && !uart_rx_pop) begin
                uart_rx_overrun_r <= 1'b1;
            end else begin
                uart_rx_data_r  <= uart_rx_byte;
                uart_rx_valid_r <= 1'b1;
            end
        end
    end
end

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        load_rdata  <= 32'd0;
        tube_status <= 8'd0;
        debug_uart_status_load_count <= 8'd0;
    end else begin
        if (load_req) begin
            if (load_addr_is_ram) begin
                load_rdata <= data_mem[load_word_idx];
            end else if (load_addr_is_tube) begin
                load_rdata <= {24'd0, tube_status};
            end else if (load_addr_is_uart_status) begin
                // bit0 remains backward-compatible TX busy; the higher bits
                // expose TX ready and RX/error state for the full UART MMIO.
                load_rdata <= uart_status_word;
                debug_uart_status_load_count <= debug_uart_status_load_count + 8'd1;
            end else if (load_addr_is_uart_rx) begin
                load_rdata <= {24'd0, uart_rx_data_r};
            end else if (load_addr_is_uart_ctrl) begin
                load_rdata <= uart_ctrl_word;
            end else begin
                load_rdata <= 32'd0;
            end
        end

        if (sb_write_valid && sb_addr_is_tube) begin
            tube_status <= select_mmio_byte(tube_status, sb_write_data, sb_write_wen);
        end
    end
end

endmodule
