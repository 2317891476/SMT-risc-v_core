`timescale 1ns/1ps

module tb_ax7203_top_uart_loader_transport_smoke;
    reg sys_clk_p;
    reg sys_clk_n;
    reg sys_rst_n;
    reg uart_rx;

    wire uart_tx;
    wire [4:0] led;
    wire [31:0] ddr3_dq;
    wire [3:0] ddr3_dqs_p;
    wire [3:0] ddr3_dqs_n;
    wire [14:0] ddr3_addr;
    wire [2:0] ddr3_ba;
    wire ddr3_ras_n;
    wire ddr3_cas_n;
    wire ddr3_we_n;
    wire ddr3_ck_p;
    wire ddr3_ck_n;
    wire ddr3_cke;
    wire ddr3_reset_n;
    wire [3:0] ddr3_dm;
    wire ddr3_odt;
    wire ddr3_cs_n;

`ifdef TB_UART_BIT_NS
    localparam integer UART_BIT_NS = `TB_UART_BIT_NS;
`else
    localparam integer UART_BIT_NS = 8680;
`endif
`ifdef TB_SHORT_TIMEOUT_NS
    localparam integer TB_TIMEOUT_NS = `TB_SHORT_TIMEOUT_NS;
`else
    localparam integer TB_TIMEOUT_NS = 80_000_000;
`endif
    localparam integer MAX_PAYLOAD_BYTES = 16384;
    localparam [159:0] READY_TOKEN = 160'h424F4F54205452414E53504F5254205245414459; // BOOT TRANSPORT READY
    localparam [79:0] LOAD_START_TOKEN = 80'h4C4F4144205354415254; // LOAD START
    localparam [55:0] READ_OK_TOKEN = 56'h52454144204F4B; // READ OK
    localparam [55:0] LOAD_OK_TOKEN = 56'h4C4F4144204F4B; // LOAD OK
    localparam [7:0] LOADER_ACK_BYTE = 8'h06;
    localparam integer TRACE_BYTE_LIMIT = 32;
    localparam integer PHY_UART_MON_CLK_DIV = 1736;
    localparam integer HEADER_GAP_BITS = 40;
    localparam integer ACK_GAP_BITS = 24;

    reg [7:0] payload [0:MAX_PAYLOAD_BYTES-1];
    integer payload_size;
    integer payload_checksum;
    integer payload_idx;
    integer dbg_uart_byte_count;
    integer phy_uart_byte_count;
    integer dbg_trace_count;
    integer phy_trace_count;
    reg saw_ready_dbg;
    reg saw_ready_phy;
    reg saw_ready_hint;
    reg saw_load_start_dbg;
    reg saw_load_start_phy;
    reg saw_load_start_hint;
    reg saw_read_ok;
    reg saw_load_ok;
    reg [191:0] dbg_shift192;
    reg [191:0] phy_shift192;
    event payload_ack_event;

    wire core_uart_tx_start = dut.core_uart_byte_valid_dbg;
    wire [7:0] core_uart_tx_byte = dut.core_uart_byte_dbg;
    wire ext_uart_byte_valid;
    wire [7:0] ext_uart_byte;
    wire [3:0] ext_uart_frame_count;
    wire ready_gate = saw_ready_dbg || saw_ready_phy || saw_ready_hint;
    wire load_start_gate = saw_load_start_dbg || saw_load_start_phy || saw_load_start_hint;

    adam_riscv_ax7203_top dut (
        .sys_clk_p   (sys_clk_p),
        .sys_clk_n   (sys_clk_n),
        .sys_rst_n   (sys_rst_n),
        .uart_tx     (uart_tx),
        .uart_rx     (uart_rx),
        .led         (led),
        .ddr3_dq     (ddr3_dq),
        .ddr3_dqs_p  (ddr3_dqs_p),
        .ddr3_dqs_n  (ddr3_dqs_n),
        .ddr3_addr   (ddr3_addr),
        .ddr3_ba     (ddr3_ba),
        .ddr3_ras_n  (ddr3_ras_n),
        .ddr3_cas_n  (ddr3_cas_n),
        .ddr3_we_n   (ddr3_we_n),
        .ddr3_ck_p   (ddr3_ck_p),
        .ddr3_ck_n   (ddr3_ck_n),
        .ddr3_cke    (ddr3_cke),
        .ddr3_reset_n(ddr3_reset_n),
        .ddr3_dm     (ddr3_dm),
        .ddr3_odt    (ddr3_odt),
        .ddr3_cs_n   (ddr3_cs_n)
    );

    uart_rx_monitor #(
        .CLK_DIV(PHY_UART_MON_CLK_DIV)
    ) u_ext_uart_monitor (
        .clk        (sys_clk_p           ),
        .rst_n      (dut.core_rst_n      ),
        .rx         (uart_tx             ),
        .frame_seen (                    ),
        .frame_count(ext_uart_frame_count),
        .byte_valid (ext_uart_byte_valid ),
        .byte_data  (ext_uart_byte       )
    );

    task automatic send_uart_byte(input [7:0] data);
        integer bit_idx;
        begin
            uart_rx = 1'b0;
            #(UART_BIT_NS);
            for (bit_idx = 0; bit_idx < 8; bit_idx = bit_idx + 1) begin
                uart_rx = data[bit_idx];
                #(UART_BIT_NS);
            end
            uart_rx = 1'b1;
            #(UART_BIT_NS);
        end
    endtask

    task automatic send_u32_le(input [31:0] data);
        begin
            send_uart_byte(data[7:0]);
            send_uart_byte(data[15:8]);
            send_uart_byte(data[23:16]);
            send_uart_byte(data[31:24]);
        end
    endtask

    task automatic send_header_frame;
        begin
            send_u32_le(32'h314B4D42);
            send_u32_le(32'h00000000);
            send_u32_le(32'h00000000);
            send_u32_le(payload_size[31:0]);
            send_u32_le(payload_checksum[31:0]);
        end
    endtask

    task automatic send_payload_chunk;
        integer chunk_idx;
        begin
            for (chunk_idx = 0; chunk_idx < 4; chunk_idx = chunk_idx + 1) begin
                if (payload_idx < payload_size) begin
                    send_uart_byte(payload[payload_idx]);
                    payload_idx = payload_idx + 1;
                end
            end
        end
    endtask

    initial begin
        sys_clk_p = 1'b0;
        sys_clk_n = 1'b1;
        forever begin
            #2.5;
            sys_clk_p = ~sys_clk_p;
            sys_clk_n = ~sys_clk_n;
        end
    end

    initial begin
        if (!$value$plusargs("PAYLOAD_SIZE=%d", payload_size)) payload_size = 0;
        if (!$value$plusargs("PAYLOAD_CHECKSUM=%d", payload_checksum)) payload_checksum = 0;
        if (payload_size <= 0 || payload_size > MAX_PAYLOAD_BYTES) begin
            $display("[AX7203_UART_TRANSPORT] bad payload_size=%0d", payload_size);
            $fatal(1);
        end
        $readmemh("uart_loader_transport_payload.hex", payload);

        sys_rst_n = 1'b0;
        uart_rx = 1'b1;
        dbg_uart_byte_count = 0;
        phy_uart_byte_count = 0;
        dbg_trace_count = 0;
        phy_trace_count = 0;
        payload_idx = 0;
        saw_ready_dbg = 1'b0;
        saw_ready_phy = 1'b0;
        saw_ready_hint = 1'b0;
        saw_load_start_dbg = 1'b0;
        saw_load_start_phy = 1'b0;
        saw_load_start_hint = 1'b0;
        saw_read_ok = 1'b0;
        saw_load_ok = 1'b0;
        dbg_shift192 = 192'd0;
        phy_shift192 = 192'd0;
        #100;
        sys_rst_n = 1'b1;
    end

    initial begin : uart_host_driver
        wait(sys_rst_n == 1'b1);
        wait(ready_gate == 1'b1);
        #(UART_BIT_NS * HEADER_GAP_BITS);
        $display("[AX7203_UART_TRANSPORT_TB] send header ready_dbg=%0b ready_phy=%0b ready_hint=%0b dbg_bytes=%0d phy_bytes=%0d tube=%02h",
                 saw_ready_dbg, saw_ready_phy, saw_ready_hint, dbg_uart_byte_count, phy_uart_byte_count, dut.tube_status);
        send_header_frame();
        wait(load_start_gate == 1'b1);
        #(UART_BIT_NS * HEADER_GAP_BITS);
        payload_idx = 0;
        while (payload_idx < payload_size) begin
            $display("[AX7203_UART_TRANSPORT_TB] send chunk start_idx=%0d", payload_idx);
            send_payload_chunk();
            if (payload_idx < payload_size) begin
                @payload_ack_event;
                #(UART_BIT_NS * ACK_GAP_BITS);
            end
        end
    end

    always @(posedge core_uart_tx_start) begin
        dbg_uart_byte_count <= dbg_uart_byte_count + 1;
        dbg_shift192 <= {dbg_shift192[183:0], core_uart_tx_byte};
        if (dbg_trace_count < TRACE_BYTE_LIMIT) begin
            if (core_uart_tx_byte >= 8'h20 && core_uart_tx_byte <= 8'h7e)
                $write("[DBG]%c", core_uart_tx_byte);
            else if (core_uart_tx_byte == 8'h0d)
                $write("[DBG]<CR>");
            else if (core_uart_tx_byte == 8'h0a)
                $write("[DBG]<LF>\n");
            else
                $write("[DBG]<%02x>", core_uart_tx_byte);
            dbg_trace_count <= dbg_trace_count + 1;
        end

        if ({dbg_shift192[151:0], core_uart_tx_byte} == READY_TOKEN) begin
            saw_ready_dbg <= 1'b1;
            $display("\n[AX7203_UART_TRANSPORT] saw READY on debug tap at byte %0d", dbg_uart_byte_count + 1);
        end
        if ({dbg_shift192[71:0], core_uart_tx_byte} == LOAD_START_TOKEN) begin
            saw_load_start_dbg <= 1'b1;
            $display("\n[AX7203_UART_TRANSPORT] saw LOAD START on debug tap at byte %0d", dbg_uart_byte_count + 1);
        end
        if ({dbg_shift192[47:0], core_uart_tx_byte} == READ_OK_TOKEN)
            saw_read_ok <= 1'b1;
        if ({dbg_shift192[47:0], core_uart_tx_byte} == LOAD_OK_TOKEN)
            saw_load_ok <= 1'b1;
    end

    always @(posedge sys_clk_p) begin
        if (!saw_ready_hint &&
            sys_rst_n &&
            dut.core_ready &&
            dut.core_retire_seen &&
            dut.mig_init_calib_complete &&
            (dut.tube_status == 8'h32) &&
            ((dbg_uart_byte_count >= 20) || (phy_uart_byte_count >= 20))) begin
            saw_ready_hint <= 1'b1;
            $display("[AX7203_UART_TRANSPORT] READY_HINT ready=%0b retire=%0b calib=%0b tube=%02h dbg_bytes=%0d phy_bytes=%0d",
                     dut.core_ready, dut.core_retire_seen, dut.mig_init_calib_complete,
                     dut.tube_status, dbg_uart_byte_count, phy_uart_byte_count);
        end
        if (!saw_load_start_hint &&
            sys_rst_n &&
            dut.core_ready &&
            dut.core_retire_seen &&
            (dut.tube_status == 8'h33) &&
            payload_idx == 0) begin
            saw_load_start_hint <= 1'b1;
            $display("[AX7203_UART_TRANSPORT] LOAD_START_HINT tube=%02h dbg_bytes=%0d phy_bytes=%0d",
                     dut.tube_status, dbg_uart_byte_count, phy_uart_byte_count);
        end
    end

    always @(posedge ext_uart_byte_valid) begin
        phy_uart_byte_count <= phy_uart_byte_count + 1;
        phy_shift192 <= {phy_shift192[183:0], ext_uart_byte};
        if (phy_trace_count < TRACE_BYTE_LIMIT) begin
            phy_trace_count <= phy_trace_count + 1;
        end

        if ({phy_shift192[151:0], ext_uart_byte} == READY_TOKEN) begin
            saw_ready_phy <= 1'b1;
            $display("\n[AX7203_UART_TRANSPORT] saw READY on uart_tx line at byte %0d", phy_uart_byte_count + 1);
        end
        if ({phy_shift192[71:0], ext_uart_byte} == LOAD_START_TOKEN) begin
            saw_load_start_phy <= 1'b1;
            $display("\n[AX7203_UART_TRANSPORT] saw LOAD START on uart_tx line at byte %0d", phy_uart_byte_count + 1);
        end
        if ({phy_shift192[47:0], ext_uart_byte} == READ_OK_TOKEN)
            saw_read_ok <= 1'b1;
        if ({phy_shift192[47:0], ext_uart_byte} == LOAD_OK_TOKEN)
            saw_load_ok <= 1'b1;
        if (ext_uart_byte == LOADER_ACK_BYTE)
            -> payload_ack_event;
    end

    initial begin : progress_trace
        forever begin
            #1_000_000;
            $display("[AX7203_UART_TRANSPORT] PROGRESS t=%0t ready=%0b retire=%0b calib=%0b tube=%02h dbg_bytes=%0d phy_bytes=%0d ready_dbg=%0b ready_phy=%0b ready_hint=%0b start_dbg=%0b start_phy=%0b start_hint=%0b read_ok=%0b load_ok=%0b payload_idx=%0d frames=%0d led=%b",
                     $time,
                     dut.core_ready,
                     dut.core_retire_seen,
                     dut.mig_init_calib_complete,
                     dut.tube_status,
                     dbg_uart_byte_count,
                     phy_uart_byte_count,
                     saw_ready_dbg,
                     saw_ready_phy,
                     saw_ready_hint,
                     saw_load_start_dbg,
                     saw_load_start_phy,
                     saw_load_start_hint,
                     saw_read_ok,
                     saw_load_ok,
                     payload_idx,
                     ext_uart_frame_count,
                     led);
        end
    end

    initial begin : timeout_guard
        #TB_TIMEOUT_NS;
        $display("[AX7203_UART_TRANSPORT] TIMEOUT ready_dbg=%0b ready_phy=%0b ready_hint=%0b start_dbg=%0b start_phy=%0b start_hint=%0b read_ok=%0b load_ok=%0b payload_idx=%0d dbg_bytes=%0d phy_bytes=%0d tube=%02h ready=%0b retire=%0b calib=%0b frames=%0d led=%b",
                 saw_ready_dbg, saw_ready_phy, saw_ready_hint,
                 saw_load_start_dbg, saw_load_start_phy, saw_load_start_hint,
                 saw_read_ok, saw_load_ok, payload_idx, dbg_uart_byte_count, phy_uart_byte_count,
                 dut.tube_status, dut.core_ready, dut.core_retire_seen, dut.mig_init_calib_complete,
                 ext_uart_frame_count, led);
        $fatal(1);
    end

    always @(posedge sys_clk_p) begin
        if (sys_rst_n && ready_gate && load_start_gate && saw_read_ok && saw_load_ok && dut.tube_status == 8'h04) begin
            $display("[AX7203_UART_TRANSPORT] PASS ready_dbg=%0b ready_phy=%0b ready_hint=%0b start_dbg=%0b start_phy=%0b start_hint=%0b read_ok=%0b load_ok=%0b payload_idx=%0d dbg_bytes=%0d phy_bytes=%0d tube=%02h frames=%0d led=%b",
                     saw_ready_dbg, saw_ready_phy, saw_ready_hint,
                     saw_load_start_dbg, saw_load_start_phy, saw_load_start_hint,
                     saw_read_ok, saw_load_ok, payload_idx, dbg_uart_byte_count, phy_uart_byte_count,
                     dut.tube_status, ext_uart_frame_count, led);
            $finish;
        end
        if (sys_rst_n && (dut.tube_status[7:4] == 4'hE)) begin
            $display("[AX7203_UART_TRANSPORT] FAIL tube=%02h ready_dbg=%0b ready_phy=%0b ready_hint=%0b start_dbg=%0b start_phy=%0b start_hint=%0b read_ok=%0b load_ok=%0b payload_idx=%0d dbg_bytes=%0d phy_bytes=%0d frames=%0d led=%b",
                     dut.tube_status,
                     saw_ready_dbg, saw_ready_phy, saw_ready_hint,
                     saw_load_start_dbg, saw_load_start_phy, saw_load_start_hint,
                     saw_read_ok, saw_load_ok, payload_idx, dbg_uart_byte_count, phy_uart_byte_count,
                     ext_uart_frame_count, led);
            $fatal(1);
        end
    end
endmodule
