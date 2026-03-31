`include "define.v"

module legacy_mem_subsys #(
    parameter RAM_WORDS = 4096
) (
    input  wire        clk,
    input  wire        rstn,

    input  wire [31:0] load_addr,
    input  wire [3:0]  load_read,
    output reg  [31:0] load_rdata,

    input  wire        sb_write_valid,
    input  wire [31:0] sb_write_addr,
    input  wire [31:0] sb_write_data,
    input  wire [3:0]  sb_write_wen,
    output wire        sb_write_ready,

    output reg  [7:0]  tube_status
);

localparam RAM_ADDR_W = $clog2(RAM_WORDS);

(* ram_style = "block" *) reg [31:0] data_mem [0:RAM_WORDS-1];

wire load_req = |load_read;
wire load_addr_is_ram = (load_addr >= `RAM_CACHEABLE_BASE) && (load_addr <= `RAM_CACHEABLE_TOP);
wire load_addr_is_tube = (load_addr == `TUBE_ADDR);
wire sb_addr_is_ram = (sb_write_addr >= `RAM_CACHEABLE_BASE) && (sb_write_addr <= `RAM_CACHEABLE_TOP);
wire sb_addr_is_tube = (sb_write_addr == `TUBE_ADDR);

wire [RAM_ADDR_W-1:0] load_word_idx = load_addr[RAM_ADDR_W+1:2];
wire [RAM_ADDR_W-1:0] sb_word_idx = sb_write_addr[RAM_ADDR_W+1:2];

assign sb_write_ready = !load_req;

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
end

always @(posedge clk) begin
    if (!load_req && sb_write_valid && sb_addr_is_ram) begin
        data_mem[sb_word_idx] <= merge_write_data(data_mem[sb_word_idx], sb_write_data, sb_write_wen);
    end
end

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        load_rdata  <= 32'd0;
        tube_status <= 8'd0;
    end else begin
        if (load_req) begin
            if (load_addr_is_ram) begin
                load_rdata <= data_mem[load_word_idx];
            end else if (load_addr_is_tube) begin
                load_rdata <= {24'd0, tube_status};
            end else begin
                load_rdata <= 32'd0;
            end
        end

        if (!load_req && sb_write_valid && sb_addr_is_tube) begin
            tube_status <= select_mmio_byte(tube_status, sb_write_data, sb_write_wen);
        end
    end
end

endmodule
