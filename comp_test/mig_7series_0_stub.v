`timescale 1ns/1ps

module mig_7series_0 (
    inout  wire [31:0] ddr3_dq,
    inout  wire [3:0]  ddr3_dqs_p,
    inout  wire [3:0]  ddr3_dqs_n,
    output wire [14:0] ddr3_addr,
    output wire [2:0]  ddr3_ba,
    output wire        ddr3_ras_n,
    output wire        ddr3_cas_n,
    output wire        ddr3_we_n,
    output wire        ddr3_ck_p,
    output wire        ddr3_ck_n,
    output wire        ddr3_cke,
    output wire        ddr3_reset_n,
    output wire [3:0]  ddr3_dm,
    output wire        ddr3_odt,
    output wire        ddr3_cs_n,
    input  wire        sys_clk_i,
    input  wire        sys_rst,
    input  wire        aresetn,
    output wire        ui_clk,
    output reg         ui_clk_sync_rst,
    output reg         mmcm_locked,
    output reg         init_calib_complete,
    input  wire        app_sr_req,
    input  wire        app_ref_req,
    input  wire        app_zq_req,
    output wire        app_sr_active,
    output wire        app_ref_ack,
    output wire        app_zq_ack,
    output wire [11:0] device_temp,
    input  wire [3:0]  s_axi_awid,
    input  wire [31:0] s_axi_awaddr,
    input  wire [7:0]  s_axi_awlen,
    input  wire [2:0]  s_axi_awsize,
    input  wire [1:0]  s_axi_awburst,
    input  wire        s_axi_awlock,
    input  wire [3:0]  s_axi_awcache,
    input  wire [2:0]  s_axi_awprot,
    input  wire [3:0]  s_axi_awqos,
    input  wire        s_axi_awvalid,
    output wire        s_axi_awready,
    input  wire [255:0] s_axi_wdata,
    input  wire [31:0] s_axi_wstrb,
    input  wire        s_axi_wlast,
    input  wire        s_axi_wvalid,
    output wire        s_axi_wready,
    output reg  [3:0]  s_axi_bid,
    output reg  [1:0]  s_axi_bresp,
    output reg         s_axi_bvalid,
    input  wire        s_axi_bready,
    input  wire [3:0]  s_axi_arid,
    input  wire [31:0] s_axi_araddr,
    input  wire [7:0]  s_axi_arlen,
    input  wire [2:0]  s_axi_arsize,
    input  wire [1:0]  s_axi_arburst,
    input  wire        s_axi_arlock,
    input  wire [3:0]  s_axi_arcache,
    input  wire [2:0]  s_axi_arprot,
    input  wire [3:0]  s_axi_arqos,
    input  wire        s_axi_arvalid,
    output wire        s_axi_arready,
    output reg  [3:0]  s_axi_rid,
    output reg  [255:0] s_axi_rdata,
    output reg  [1:0]  s_axi_rresp,
    output reg         s_axi_rlast,
    output reg         s_axi_rvalid,
    input  wire        s_axi_rready
);

localparam integer MEM_LINES = 4096;
localparam integer CALIB_CYCLES = 64;

reg [255:0] mem [0:MEM_LINES-1];
reg [7:0] calib_ctr;
reg aw_seen;
reg [3:0] aw_id_r;
reg [31:0] aw_addr_r;
reg w_seen;
reg [255:0] w_data_r;
reg [31:0] w_strb_r;
reg ar_pending;
reg [3:0] ar_id_r;
reg [31:0] ar_addr_r;

integer idx;
integer byte_idx;

wire rstn = aresetn & sys_rst;
wire calib_done = init_calib_complete;

assign ui_clk = sys_clk_i;
assign ddr3_dq = 32'hZZZZ_ZZZZ;
assign ddr3_dqs_p = 4'hZ;
assign ddr3_dqs_n = 4'hZ;
assign ddr3_addr = 15'd0;
assign ddr3_ba = 3'd0;
assign ddr3_ras_n = 1'b1;
assign ddr3_cas_n = 1'b1;
assign ddr3_we_n = 1'b1;
assign ddr3_ck_p = sys_clk_i;
assign ddr3_ck_n = ~sys_clk_i;
assign ddr3_cke = calib_done;
assign ddr3_reset_n = rstn;
assign ddr3_dm = 4'd0;
assign ddr3_odt = 1'b0;
assign ddr3_cs_n = 1'b0;
assign app_sr_active = 1'b0;
assign app_ref_ack = app_ref_req;
assign app_zq_ack = app_zq_req;
assign device_temp = 12'd0;

assign s_axi_awready = calib_done;
assign s_axi_wready = calib_done;
assign s_axi_arready = calib_done && !s_axi_rvalid && !ar_pending;

function [11:0] line_index;
    input [31:0] addr;
    begin
        line_index = addr[16:5];
    end
endfunction

always @(posedge ui_clk or negedge rstn) begin
    if (!rstn) begin
        ui_clk_sync_rst <= 1'b1;
        mmcm_locked <= 1'b0;
        init_calib_complete <= 1'b0;
        calib_ctr <= 8'd0;
        aw_seen <= 1'b0;
        aw_id_r <= 4'd0;
        aw_addr_r <= 32'd0;
        w_seen <= 1'b0;
        w_data_r <= 256'd0;
        w_strb_r <= 32'd0;
        ar_pending <= 1'b0;
        ar_id_r <= 4'd0;
        ar_addr_r <= 32'd0;
        s_axi_bid <= 4'd0;
        s_axi_bresp <= 2'b00;
        s_axi_bvalid <= 1'b0;
        s_axi_rid <= 4'd0;
        s_axi_rdata <= 256'd0;
        s_axi_rresp <= 2'b00;
        s_axi_rlast <= 1'b0;
        s_axi_rvalid <= 1'b0;
        for (idx = 0; idx < MEM_LINES; idx = idx + 1) begin
            mem[idx] <= 256'd0;
        end
    end else begin
        if (!init_calib_complete) begin
            calib_ctr <= calib_ctr + 8'd1;
            if (calib_ctr == CALIB_CYCLES-1) begin
                init_calib_complete <= 1'b1;
                ui_clk_sync_rst <= 1'b0;
                mmcm_locked <= 1'b1;
            end
        end

        if (s_axi_bvalid && s_axi_bready) begin
            s_axi_bvalid <= 1'b0;
        end

        if (s_axi_rvalid && s_axi_rready) begin
            s_axi_rvalid <= 1'b0;
            s_axi_rlast <= 1'b0;
        end

        if (calib_done) begin
            if (s_axi_awvalid && s_axi_awready && !aw_seen) begin
                aw_seen <= 1'b1;
                aw_id_r <= s_axi_awid;
                aw_addr_r <= s_axi_awaddr;
            end

            if (s_axi_wvalid && s_axi_wready && !w_seen) begin
                w_seen <= 1'b1;
                w_data_r <= s_axi_wdata;
                w_strb_r <= s_axi_wstrb;
            end

            if (aw_seen && w_seen && !s_axi_bvalid) begin
                for (byte_idx = 0; byte_idx < 32; byte_idx = byte_idx + 1) begin
                    if (w_strb_r[byte_idx]) begin
                        mem[line_index(aw_addr_r)][byte_idx*8 +: 8] <= w_data_r[byte_idx*8 +: 8];
                    end
                end
                s_axi_bid <= aw_id_r;
                s_axi_bresp <= 2'b00;
                s_axi_bvalid <= 1'b1;
                aw_seen <= 1'b0;
                w_seen <= 1'b0;
            end

            if (s_axi_arvalid && s_axi_arready) begin
                ar_pending <= 1'b1;
                ar_id_r <= s_axi_arid;
                ar_addr_r <= s_axi_araddr;
            end

            if (ar_pending && !s_axi_rvalid) begin
                s_axi_rid <= ar_id_r;
                s_axi_rdata <= mem[line_index(ar_addr_r)];
                s_axi_rresp <= 2'b00;
                s_axi_rlast <= 1'b1;
                s_axi_rvalid <= 1'b1;
                ar_pending <= 1'b0;
            end
        end
    end
end

endmodule
