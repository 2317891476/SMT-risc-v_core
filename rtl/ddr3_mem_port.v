// =============================================================================
// Module : ddr3_mem_port
// Description: DDR3 memory access bridge with clock domain crossing.
//   Converts the simple request/response protocol from mem_subsys (core clock
//   domain) into AXI4 transactions for the MIG DDR3 controller (ui_clk domain).
//
//   Features:
//   - Async handshake CDC (core_clk ↔ ui_clk)
//   - 32-bit word ↔ 256-bit AXI data width conversion
//   - Single-beat AXI transfers (ARLEN=0, AWLEN=0)
//   - Word-level read/write with proper byte lane steering
//
//   Address mapping:
//   - Input addr[29:0] → DDR3 byte address (upper bits stripped by mem_subsys)
//   - Word offset within 256-bit beat: addr[4:2] selects 1-of-8 words
//   - AXI address: addr[29:0] aligned to 32-byte boundary
// =============================================================================
`include "define.v"

module ddr3_mem_port #(
    parameter AXI_DATA_W  = 256,
    parameter AXI_ADDR_W  = 30,   // 1GB DDR3 = 30-bit address
    parameter AXI_ID_W    = 4
)(
    // ═══════════════════════════════════════════════════════════════════════
    // Core clock domain (from mem_subsys)
    // ═══════════════════════════════════════════════════════════════════════
    input  wire        core_clk,
    input  wire        core_rstn,

    // Simple request/response (same protocol as mem_subsys M1)
    input  wire        req_valid,
    output wire        req_ready,
    input  wire [31:0] req_addr,      // Full 32-bit CPU address
    input  wire        req_write,     // 0=read, 1=write
    input  wire [31:0] req_wdata,     // Write data (32-bit word)
    input  wire [3:0]  req_wen,       // Byte write enable
    output wire        resp_valid,
    output wire [31:0] resp_data,

    // ═══════════════════════════════════════════════════════════════════════
    // MIG UI clock domain
    // ═══════════════════════════════════════════════════════════════════════
    input  wire        ui_clk,
    input  wire        ui_rstn,
    input  wire        init_calib_complete,  // MIG calibration done

    // AXI4 Master → MIG Slave
    // Write Address Channel
    output reg                       m_axi_awvalid,
    input  wire                      m_axi_awready,
    output wire [AXI_ID_W-1:0]      m_axi_awid,
    output reg  [AXI_ADDR_W-1:0]    m_axi_awaddr,
    output wire [7:0]                m_axi_awlen,
    output wire [2:0]                m_axi_awsize,
    output wire [1:0]                m_axi_awburst,
    output wire                      m_axi_awlock,
    output wire [3:0]                m_axi_awcache,
    output wire [2:0]                m_axi_awprot,
    output wire [3:0]                m_axi_awqos,

    // Write Data Channel
    output reg                       m_axi_wvalid,
    input  wire                      m_axi_wready,
    output reg  [AXI_DATA_W-1:0]    m_axi_wdata,
    output reg  [AXI_DATA_W/8-1:0]  m_axi_wstrb,
    output wire                      m_axi_wlast,

    // Write Response Channel
    input  wire                      m_axi_bvalid,
    output wire                      m_axi_bready,
    input  wire [AXI_ID_W-1:0]      m_axi_bid,
    input  wire [1:0]                m_axi_bresp,

    // Read Address Channel
    output reg                       m_axi_arvalid,
    input  wire                      m_axi_arready,
    output wire [AXI_ID_W-1:0]      m_axi_arid,
    output reg  [AXI_ADDR_W-1:0]    m_axi_araddr,
    output wire [7:0]                m_axi_arlen,
    output wire [2:0]                m_axi_arsize,
    output wire [1:0]                m_axi_arburst,
    output wire                      m_axi_arlock,
    output wire [3:0]                m_axi_arcache,
    output wire [2:0]                m_axi_arprot,
    output wire [3:0]                m_axi_arqos,

    // Read Data Channel
    input  wire                      m_axi_rvalid,
    output wire                      m_axi_rready,
    input  wire [AXI_ID_W-1:0]      m_axi_rid,
    input  wire [AXI_DATA_W-1:0]    m_axi_rdata,
    input  wire [1:0]               m_axi_rresp,
    input  wire                      m_axi_rlast
);

// ═════════════════════════════════════════════════════════════════════════════
// AXI constant signals (single-beat, non-burst, normal access)
// ═════════════════════════════════════════════════════════════════════════════
assign m_axi_awid    = {AXI_ID_W{1'b0}};
assign m_axi_awlen   = 8'd0;             // Single beat
assign m_axi_awsize  = 3'b101;           // 32 bytes (256 bits)
assign m_axi_awburst = 2'b01;            // INCR
assign m_axi_awlock  = 1'b0;
assign m_axi_awcache = 4'b0011;          // Normal non-cacheable bufferable
assign m_axi_awprot  = 3'b000;
assign m_axi_awqos   = 4'b0000;
assign m_axi_wlast   = 1'b1;             // Always last (single beat)
assign m_axi_bready  = 1'b1;             // Always accept write responses

assign m_axi_arid    = {AXI_ID_W{1'b0}};
assign m_axi_arlen   = 8'd0;             // Single beat
assign m_axi_arsize  = 3'b101;           // 32 bytes (256 bits)
assign m_axi_arburst = 2'b01;            // INCR
assign m_axi_arlock  = 1'b0;
assign m_axi_arcache = 4'b0011;
assign m_axi_arprot  = 3'b000;
assign m_axi_arqos   = 4'b0000;
assign m_axi_rready  = 1'b1;             // Always accept read data

// ═════════════════════════════════════════════════════════════════════════════
// CDC: Core domain → UI domain (request handshake)
// ═════════════════════════════════════════════════════════════════════════════

// Request capture in core domain
reg         req_flag_core;     // Toggle flag in core domain
reg [31:0]  req_addr_r;
reg         req_write_r;
reg [31:0]  req_wdata_r;
reg [3:0]   req_wen_r;
reg         req_pending;       // Request waiting for response

// Synchronize request flag to UI domain
(* ASYNC_REG = "TRUE" *) reg [2:0] req_flag_ui_sync;
wire req_flag_ui = req_flag_ui_sync[2];
reg  req_flag_ui_prev;
wire req_pulse_ui = (req_flag_ui != req_flag_ui_prev);

// Synchronize request payload into UI domain. The source-side request registers
// stay stable for the full request lifetime, so by the time the toggle reaches
// the UI domain these synchronized copies have settled as well.
(* ASYNC_REG = "TRUE" *) reg [31:0] req_addr_ui_sync0;
(* ASYNC_REG = "TRUE" *) reg [31:0] req_addr_ui_sync1;
(* ASYNC_REG = "TRUE" *) reg        req_write_ui_sync0;
(* ASYNC_REG = "TRUE" *) reg        req_write_ui_sync1;
(* ASYNC_REG = "TRUE" *) reg [31:0] req_wdata_ui_sync0;
(* ASYNC_REG = "TRUE" *) reg [31:0] req_wdata_ui_sync1;
(* ASYNC_REG = "TRUE" *) reg [3:0]  req_wen_ui_sync0;
(* ASYNC_REG = "TRUE" *) reg [3:0]  req_wen_ui_sync1;

// Level-based pending flag: survives until FSM actually consumes the request.
// Fixes race where req_pulse_ui fires before init_calib_complete.
reg  req_pending_ui;

localparam UI_IDLE      = 3'd0;
localparam UI_RD_ADDR   = 3'd1;
localparam UI_RD_DATA   = 3'd2;
localparam UI_WR_ADDR   = 3'd3;
localparam UI_WR_DATA   = 3'd4;
localparam UI_WR_RESP   = 3'd5;
localparam UI_DONE      = 3'd6;

reg [2:0] ui_state;

// Synchronize response flag to core domain
reg         resp_flag_ui;      // Toggle flag in UI domain
(* ASYNC_REG = "TRUE" *) reg [2:0] resp_flag_core_sync;
wire resp_flag_core = resp_flag_core_sync[2];
reg  resp_flag_core_prev;
wire resp_pulse_core = (resp_flag_core != resp_flag_core_prev);

// Response data captured in UI domain, read in core domain
reg [31:0]  resp_data_ui;      // UI domain response word
(* ASYNC_REG = "TRUE" *) reg [31:0] resp_data_core_sync0;
(* ASYNC_REG = "TRUE" *) reg [31:0] resp_data_core_sync1;
reg [31:0]  resp_data_r;       // Core domain captured response

`ifdef DDR3_BRIDGE_AUDIT
localparam integer CORE_REQ_TIMEOUT_CYCLES = 16'd1024;
localparam integer UI_STATE_TIMEOUT_CYCLES = 16'd2048;

reg [31:0] debug_core_req_accept_count_r;
reg [31:0] debug_ui_req_consume_count_r;
reg [31:0] debug_axi_ar_count_r;
reg [31:0] debug_axi_r_count_r;
reg [31:0] debug_axi_aw_count_r;
reg [31:0] debug_axi_w_count_r;
reg [31:0] debug_axi_b_count_r;
reg [31:0] debug_resp_toggle_count_r;
reg        debug_req_pending_timeout_flag_r;
reg        debug_ui_state_stuck_flag_r;
reg        debug_duplicate_resp_core_flag_r;
reg        debug_duplicate_resp_ui_flag_r;
wire       debug_duplicate_resp_flag_r = debug_duplicate_resp_core_flag_r | debug_duplicate_resp_ui_flag_r;
reg [31:0] debug_last_req_addr_r;
reg        debug_last_req_write_r;
reg [31:0] debug_last_resp_data_r;
reg [15:0] debug_req_pending_age_r;
reg [15:0] debug_ui_state_age_r;
reg [2:0]  debug_ui_state_prev_r;
reg        debug_prev_bvalid_r;
reg        debug_prev_rvalid_r;
`endif

// ── Core domain logic ──

assign req_ready  = !req_pending && core_rstn;
assign resp_valid = resp_pulse_core;
assign resp_data  = resp_pulse_core ? resp_data_core_sync1 : resp_data_r;

always @(posedge core_clk or negedge core_rstn) begin
    if (!core_rstn) begin
        req_flag_core      <= 1'b0;
        req_addr_r         <= 32'd0;
        req_write_r        <= 1'b0;
        req_wdata_r        <= 32'd0;
        req_wen_r          <= 4'd0;
        req_pending        <= 1'b0;
        resp_flag_core_sync <= 3'b0;
        resp_flag_core_prev <= 1'b0;
        resp_data_core_sync0 <= 32'd0;
        resp_data_core_sync1 <= 32'd0;
        resp_data_r        <= 32'd0;
`ifdef DDR3_BRIDGE_AUDIT
        debug_core_req_accept_count_r   <= 32'd0;
        debug_req_pending_timeout_flag_r <= 1'b0;
        debug_duplicate_resp_core_flag_r <= 1'b0;
        debug_last_req_addr_r           <= 32'd0;
        debug_last_req_write_r          <= 1'b0;
        debug_last_resp_data_r          <= 32'd0;
        debug_req_pending_age_r         <= 16'd0;
`endif
    end else begin
        // Synchronize response flag
        resp_flag_core_sync <= {resp_flag_core_sync[1:0], resp_flag_ui};
        resp_flag_core_prev <= resp_flag_core;
        resp_data_core_sync0 <= resp_data_ui;
        resp_data_core_sync1 <= resp_data_core_sync0;

`ifdef DDR3_BRIDGE_AUDIT
        if (req_pending) begin
            if (!resp_pulse_core) begin
                if (debug_req_pending_age_r != 16'hFFFF)
                    debug_req_pending_age_r <= debug_req_pending_age_r + 16'd1;
                if (debug_req_pending_age_r == (CORE_REQ_TIMEOUT_CYCLES - 1))
                    debug_req_pending_timeout_flag_r <= 1'b1;
            end else begin
                debug_req_pending_age_r <= 16'd0;
            end
        end else begin
            debug_req_pending_age_r <= 16'd0;
        end
`endif

        // Accept new request
        if (req_valid && !req_pending) begin
            req_addr_r    <= req_addr;
            req_write_r   <= req_write;
            req_wdata_r   <= req_wdata;
            req_wen_r     <= req_wen;
            req_flag_core <= ~req_flag_core;  // Toggle to signal UI domain
            req_pending   <= 1'b1;
`ifdef DDR3_BRIDGE_AUDIT
            debug_core_req_accept_count_r <= debug_core_req_accept_count_r + 32'd1;
            debug_last_req_addr_r         <= req_addr;
            debug_last_req_write_r        <= req_write;
`endif
        end

        // Capture response
        if (resp_pulse_core) begin
`ifdef DDR3_BRIDGE_AUDIT
            if (!req_pending)
                debug_duplicate_resp_core_flag_r <= 1'b1;
            debug_last_resp_data_r <= resp_data_core_sync1;
`endif
            req_pending <= 1'b0;
            resp_data_r <= resp_data_core_sync1;
        end
    end
end

// ── UI domain logic ──

always @(posedge ui_clk or negedge ui_rstn) begin
    if (!ui_rstn) begin
        req_flag_ui_sync  <= 3'b0;
        req_flag_ui_prev  <= 1'b0;
        req_pending_ui    <= 1'b0;
        req_addr_ui_sync0 <= 32'd0;
        req_addr_ui_sync1 <= 32'd0;
        req_write_ui_sync0 <= 1'b0;
        req_write_ui_sync1 <= 1'b0;
        req_wdata_ui_sync0 <= 32'd0;
        req_wdata_ui_sync1 <= 32'd0;
        req_wen_ui_sync0  <= 4'd0;
        req_wen_ui_sync1  <= 4'd0;
    end else begin
        req_flag_ui_sync  <= {req_flag_ui_sync[1:0], req_flag_core};
        req_flag_ui_prev  <= req_flag_ui;
        req_addr_ui_sync0 <= req_addr_r;
        req_addr_ui_sync1 <= req_addr_ui_sync0;
        req_write_ui_sync0 <= req_write_r;
        req_write_ui_sync1 <= req_write_ui_sync0;
        req_wdata_ui_sync0 <= req_wdata_r;
        req_wdata_ui_sync1 <= req_wdata_ui_sync0;
        req_wen_ui_sync0  <= req_wen_r;
        req_wen_ui_sync1  <= req_wen_ui_sync0;
        // Latch pulse into a level-based pending flag. Preserve a newly
        // arrived request if it lands in the same cycle that UI_IDLE consumes
        // the previous one; clearing in that case drops the next transaction
        // and wedges the core-side requester forever waiting on a response.
        if (req_pulse_ui)
            req_pending_ui <= 1'b1;
        else if (ui_state == UI_IDLE && req_pending_ui && init_calib_complete)
            req_pending_ui <= 1'b0;
    end
end

// ═════════════════════════════════════════════════════════════════════════════
// UI domain: AXI transaction FSM
// ═════════════════════════════════════════════════════════════════════════════

// Latch request parameters in UI domain
reg [31:0] ui_addr;
reg        ui_write;
reg [31:0] ui_wdata;
reg [3:0]  ui_wen;

// Word offset within the 256-bit beat (addr[4:2] = 3 bits → 0-7)
wire [2:0] word_offset = ui_addr[4:2];

always @(posedge ui_clk or negedge ui_rstn) begin
    if (!ui_rstn) begin
        ui_state        <= UI_IDLE;
        ui_addr         <= 32'd0;
        ui_write        <= 1'b0;
        ui_wdata        <= 32'd0;
        ui_wen          <= 4'd0;
        resp_flag_ui    <= 1'b0;
        resp_data_ui    <= 32'd0;
        m_axi_awvalid   <= 1'b0;
        m_axi_awaddr    <= {AXI_ADDR_W{1'b0}};
        m_axi_wvalid    <= 1'b0;
        m_axi_wdata     <= {AXI_DATA_W{1'b0}};
        m_axi_wstrb     <= {(AXI_DATA_W/8){1'b0}};
        m_axi_arvalid   <= 1'b0;
        m_axi_araddr    <= {AXI_ADDR_W{1'b0}};
`ifdef DDR3_BRIDGE_AUDIT
        debug_ui_req_consume_count_r <= 32'd0;
        debug_axi_ar_count_r         <= 32'd0;
        debug_axi_r_count_r          <= 32'd0;
        debug_axi_aw_count_r         <= 32'd0;
        debug_axi_w_count_r          <= 32'd0;
        debug_axi_b_count_r          <= 32'd0;
        debug_resp_toggle_count_r    <= 32'd0;
        debug_ui_state_stuck_flag_r  <= 1'b0;
        debug_duplicate_resp_ui_flag_r <= 1'b0;
        debug_ui_state_age_r         <= 16'd0;
        debug_ui_state_prev_r        <= 3'd0;
        debug_prev_bvalid_r          <= 1'b0;
        debug_prev_rvalid_r          <= 1'b0;
`endif
    end else begin
`ifdef DDR3_BRIDGE_AUDIT
        if (ui_state != UI_IDLE) begin
            if (ui_state == debug_ui_state_prev_r) begin
                if (debug_ui_state_age_r != 16'hFFFF)
                    debug_ui_state_age_r <= debug_ui_state_age_r + 16'd1;
                if (debug_ui_state_age_r == (UI_STATE_TIMEOUT_CYCLES - 1))
                    debug_ui_state_stuck_flag_r <= 1'b1;
            end else begin
                debug_ui_state_age_r <= 16'd0;
            end
        end else begin
            debug_ui_state_age_r <= 16'd0;
        end
        debug_ui_state_prev_r <= ui_state;
        debug_prev_bvalid_r   <= m_axi_bvalid;
        debug_prev_rvalid_r   <= m_axi_rvalid;
`endif
        case (ui_state)
            UI_IDLE: begin
                if (req_pending_ui && init_calib_complete) begin
                    // Latch request from synchronized UI-domain copies.
                    ui_addr  <= req_addr_ui_sync1;
                    ui_write <= req_write_ui_sync1;
                    ui_wdata <= req_wdata_ui_sync1;
                    ui_wen   <= req_wen_ui_sync1;
`ifdef DDR3_BRIDGE_AUDIT
                    debug_ui_req_consume_count_r <= debug_ui_req_consume_count_r + 32'd1;
`endif
                    if (req_write_ui_sync1)
                        ui_state <= UI_WR_ADDR;
                    else
                        ui_state <= UI_RD_ADDR;
                end
            end

            // ── Read path ──
            UI_RD_ADDR: begin
                m_axi_arvalid <= 1'b1;
                m_axi_araddr  <= {ui_addr[AXI_ADDR_W-1:5], 5'b0};  // 32B aligned
                ui_state      <= UI_RD_DATA;
            end

            UI_RD_DATA: begin
                if (m_axi_arready)
                    m_axi_arvalid <= 1'b0;
`ifdef DDR3_BRIDGE_AUDIT
                if (m_axi_rvalid && !debug_prev_rvalid_r)
                    debug_axi_r_count_r <= debug_axi_r_count_r + 32'd1;
`endif
                if (m_axi_rvalid) begin
                    // Extract the 32-bit word from the 256-bit response
                    case (word_offset)
                        3'd0: resp_data_ui <= m_axi_rdata[ 31:  0];
                        3'd1: resp_data_ui <= m_axi_rdata[ 63: 32];
                        3'd2: resp_data_ui <= m_axi_rdata[ 95: 64];
                        3'd3: resp_data_ui <= m_axi_rdata[127: 96];
                        3'd4: resp_data_ui <= m_axi_rdata[159:128];
                        3'd5: resp_data_ui <= m_axi_rdata[191:160];
                        3'd6: resp_data_ui <= m_axi_rdata[223:192];
                        3'd7: resp_data_ui <= m_axi_rdata[255:224];
                    endcase
                    m_axi_arvalid <= 1'b0;
                    ui_state      <= UI_DONE;
                end
            end

            // ── Write path ──
            UI_WR_ADDR: begin
                m_axi_awvalid <= 1'b1;
                m_axi_awaddr  <= {ui_addr[AXI_ADDR_W-1:5], 5'b0};  // 32B aligned

                // Prepare write data: place 32-bit word at correct lane.
                // Each case produces a complete wdata/wstrb in one assignment
                // to avoid synthesis issues with overlapping non-blocking writes.
                m_axi_wvalid <= 1'b1;
                case (word_offset)
                    3'd0: begin m_axi_wdata <= {{224{1'b0}}, ui_wdata};                            m_axi_wstrb <= {{28{1'b0}}, ui_wen}; end
                    3'd1: begin m_axi_wdata <= {{192{1'b0}}, ui_wdata, { 32{1'b0}}};               m_axi_wstrb <= {{24{1'b0}}, ui_wen, { 4{1'b0}}}; end
                    3'd2: begin m_axi_wdata <= {{160{1'b0}}, ui_wdata, { 64{1'b0}}};               m_axi_wstrb <= {{20{1'b0}}, ui_wen, { 8{1'b0}}}; end
                    3'd3: begin m_axi_wdata <= {{128{1'b0}}, ui_wdata, { 96{1'b0}}};               m_axi_wstrb <= {{16{1'b0}}, ui_wen, {12{1'b0}}}; end
                    3'd4: begin m_axi_wdata <= {{ 96{1'b0}}, ui_wdata, {128{1'b0}}};               m_axi_wstrb <= {{12{1'b0}}, ui_wen, {16{1'b0}}}; end
                    3'd5: begin m_axi_wdata <= {{ 64{1'b0}}, ui_wdata, {160{1'b0}}};               m_axi_wstrb <= {{ 8{1'b0}}, ui_wen, {20{1'b0}}}; end
                    3'd6: begin m_axi_wdata <= {{ 32{1'b0}}, ui_wdata, {192{1'b0}}};               m_axi_wstrb <= {{ 4{1'b0}}, ui_wen, {24{1'b0}}}; end
                    3'd7: begin m_axi_wdata <= {             ui_wdata, {224{1'b0}}};               m_axi_wstrb <= {             ui_wen, {28{1'b0}}}; end
                endcase
                ui_state <= UI_WR_DATA;
            end

            UI_WR_DATA: begin
                if (m_axi_awready)
                    m_axi_awvalid <= 1'b0;
                if (m_axi_wready)
                    m_axi_wvalid <= 1'b0;
                // Wait for both address and data to be accepted
                if ((!m_axi_awvalid || m_axi_awready) &&
                    (!m_axi_wvalid  || m_axi_wready)) begin
                    m_axi_awvalid <= 1'b0;
                    m_axi_wvalid  <= 1'b0;
                    ui_state      <= UI_WR_RESP;
                end
            end

            UI_WR_RESP: begin
`ifdef DDR3_BRIDGE_AUDIT
                if (m_axi_bvalid && !debug_prev_bvalid_r)
                    debug_axi_b_count_r <= debug_axi_b_count_r + 32'd1;
`endif
                if (m_axi_bvalid) begin
                    resp_data_ui <= 32'd0;  // Write response has no data
                    ui_state     <= UI_DONE;
                end
            end

            UI_DONE: begin
`ifdef DDR3_BRIDGE_AUDIT
                debug_resp_toggle_count_r <= debug_resp_toggle_count_r + 32'd1;
`endif
                resp_flag_ui <= ~resp_flag_ui;  // Toggle to signal core domain
                ui_state     <= UI_IDLE;
            end

            default: ui_state <= UI_IDLE;
        endcase

`ifdef DDR3_BRIDGE_AUDIT
        if (m_axi_arvalid && m_axi_arready)
            debug_axi_ar_count_r <= debug_axi_ar_count_r + 32'd1;
        if (m_axi_awvalid && m_axi_awready)
            debug_axi_aw_count_r <= debug_axi_aw_count_r + 32'd1;
        if (m_axi_wvalid && m_axi_wready)
            debug_axi_w_count_r <= debug_axi_w_count_r + 32'd1;

        if ((m_axi_rvalid && (ui_state != UI_RD_DATA)) ||
            (m_axi_bvalid && (ui_state != UI_WR_RESP)))
            debug_duplicate_resp_ui_flag_r <= 1'b1;
`endif
    end
end

endmodule
