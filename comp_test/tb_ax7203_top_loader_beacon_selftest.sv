module tb_ax7203_top_loader_beacon_selftest;
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

`ifdef TB_SHORT_TIMEOUT_NS
    localparam integer TB_TIMEOUT_NS = `TB_SHORT_TIMEOUT_NS;
`else
    localparam integer TB_TIMEOUT_NS = 50_000_000;
`endif

    localparam [7:0] BEACON_SOF = 8'hA5;
    localparam integer EXPECTED_EVT_COUNT = 14;
    localparam [7:0] EVT_READY = 8'h01;
    localparam [7:0] EVT_LOAD_START = 8'h02;
    localparam [7:0] EVT_BLOCK_ACK = 8'h11;
    localparam [7:0] EVT_HDR_B0_RX = 8'h31;
    localparam [7:0] EVT_HDR_B1_RX = 8'h32;
    localparam [7:0] EVT_HDR_B2_RX = 8'h33;
    localparam [7:0] EVT_HDR_B3_RX = 8'h34;
    localparam [7:0] EVT_HDR_MAGIC_OK = 8'h35;
    localparam [7:0] EVT_IDLE_OK = 8'h36;
    localparam [7:0] EVT_TRAIN_START = 8'h37;
    localparam [7:0] EVT_TRAIN_DONE = 8'h38;
    localparam [7:0] EVT_FLUSH_DONE = 8'h39;
    localparam [7:0] EVT_HEADER_ENTER = 8'h3A;
    localparam [7:0] EVT_SUMMARY = 8'hF0;

    integer match_count;
    integer unique_good_frames;
    integer duplicate_frames;
    integer good_frames;
    integer bad_frames;
    reg saw_summary;
    reg order_error;
    reg [255:0] seen_seq_bitmap;
    reg [7:0] beacon_buf [0:4];
    reg [7:0] calc_chk;
    integer beacon_idx;
    reg beacon_collecting;
    reg last_event_valid;
    reg [7:0] last_event_seq;
    reg [7:0] last_event_type;
    reg [7:0] last_event_arg;

    function automatic [7:0] expected_type(input integer idx);
        begin
            case (idx)
                0: expected_type = EVT_READY;
                1: expected_type = EVT_IDLE_OK;
                2: expected_type = EVT_TRAIN_START;
                3: expected_type = EVT_TRAIN_DONE;
                4: expected_type = EVT_FLUSH_DONE;
                5: expected_type = EVT_HEADER_ENTER;
                6: expected_type = EVT_HDR_B0_RX;
                7: expected_type = EVT_HDR_B1_RX;
                8: expected_type = EVT_HDR_B2_RX;
                9: expected_type = EVT_HDR_B3_RX;
                10: expected_type = EVT_HDR_MAGIC_OK;
                11: expected_type = EVT_LOAD_START;
                12: expected_type = EVT_BLOCK_ACK;
                13: expected_type = EVT_SUMMARY;
                default: expected_type = 8'hFF;
            endcase
        end
    endfunction

    function automatic [7:0] expected_arg(input integer idx);
        begin
            case (idx)
                0: expected_arg = 8'hA1;
                1: expected_arg = 8'hB2;
                2: expected_arg = 8'hC3;
                3: expected_arg = 8'h14;
                4: expected_arg = 8'h05;
                5: expected_arg = 8'hD6;
                6: expected_arg = 8'h42;
                7: expected_arg = 8'h4D;
                8: expected_arg = 8'h4B;
                9: expected_arg = 8'h31;
                10: expected_arg = 8'hE7;
                11: expected_arg = 8'hF8;
                12: expected_arg = 8'h00;
                13: expected_arg = 8'h0F;
                default: expected_arg = 8'hFF;
            endcase
        end
    endfunction

    wire core_uart_tx_start = dut.core_uart_byte_valid_dbg;
    wire [7:0] core_uart_tx_byte = dut.core_uart_byte_dbg;

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

    task automatic handle_beacon_event(input [7:0] seq, input [7:0] evt_type, input [7:0] evt_arg);
        begin
            if (last_event_valid &&
                (seq == last_event_seq) &&
                (evt_type == last_event_type) &&
                (evt_arg == last_event_arg)) begin
                duplicate_frames = duplicate_frames + 1;
            end else if (seen_seq_bitmap[seq]) begin
                order_error = 1'b1;
                $display("[AX7203_DDR3_LOADER_EVT] duplicate seq=%02x type=%02x arg=%02x", seq, evt_type, evt_arg);
            end else begin
                seen_seq_bitmap[seq] = 1'b1;
                last_event_valid = 1'b1;
                last_event_seq = seq;
                last_event_type = evt_type;
                last_event_arg = evt_arg;
                unique_good_frames = unique_good_frames + 1;
                $display("[AX7203_DDR3_LOADER_EVT] seq=%02x type=%02x arg=%02x", seq, evt_type, evt_arg);
                if (match_count >= EXPECTED_EVT_COUNT) begin
                    order_error = 1'b1;
                end else if ((evt_type != expected_type(match_count)) || (evt_arg != expected_arg(match_count))) begin
                    order_error = 1'b1;
                end else begin
                    match_count = match_count + 1;
                end
                if (evt_type == EVT_SUMMARY)
                    saw_summary = 1'b1;
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
        sys_rst_n = 1'b0;
        uart_rx = 1'b1;
        match_count = 0;
        unique_good_frames = 0;
        duplicate_frames = 0;
        good_frames = 0;
        bad_frames = 0;
        saw_summary = 1'b0;
        order_error = 1'b0;
        seen_seq_bitmap = 256'd0;
        beacon_idx = 0;
        beacon_collecting = 1'b0;
        last_event_valid = 1'b0;
        last_event_seq = 8'd0;
        last_event_type = 8'd0;
        last_event_arg = 8'd0;
        #100;
        sys_rst_n = 1'b1;
    end

    always @(posedge core_uart_tx_start) begin
        if (!beacon_collecting && (core_uart_tx_byte == BEACON_SOF)) begin
            beacon_collecting = 1'b1;
            beacon_idx = 1;
            beacon_buf[0] = core_uart_tx_byte;
        end else if (beacon_collecting) begin
            beacon_buf[beacon_idx] = core_uart_tx_byte;
            if (beacon_idx == 4) begin
                calc_chk = beacon_buf[0] ^ beacon_buf[1] ^ beacon_buf[2] ^ beacon_buf[3];
                if ((beacon_buf[0] == BEACON_SOF) && (calc_chk == core_uart_tx_byte)) begin
                    good_frames = good_frames + 1;
                    handle_beacon_event(beacon_buf[1], beacon_buf[2], beacon_buf[3]);
                end else begin
                    bad_frames = bad_frames + 1;
                    order_error = 1'b1;
                    $display("[AX7203_DDR3_LOADER_EVT] bad frame bytes=%02x %02x %02x %02x %02x",
                             beacon_buf[0], beacon_buf[1], beacon_buf[2], beacon_buf[3], core_uart_tx_byte);
                end
                beacon_collecting = 1'b0;
                beacon_idx = 0;
            end else begin
                beacon_idx = beacon_idx + 1;
            end
        end
    end

    initial begin : timeout_guard
        #TB_TIMEOUT_NS;
        $display("[AX7203_LOADER_BEACON_SELFTEST] TIMEOUT match_count=%0d unique=%0d dup=%0d good=%0d bad=%0d summary=%0b order_error=%0b tube=%02h led=%b",
                 match_count, unique_good_frames, duplicate_frames, good_frames, bad_frames, saw_summary, order_error, dut.tube_status, led);
        $fatal(1);
    end

    always @(posedge sys_clk_p) begin
        if (sys_rst_n && saw_summary &&
            (match_count == EXPECTED_EVT_COUNT) &&
            (unique_good_frames == EXPECTED_EVT_COUNT) &&
            (bad_frames == 0) && !order_error) begin
            $display("[AX7203_LOADER_BEACON_SELFTEST] PASS match_count=%0d unique=%0d dup=%0d good=%0d bad=%0d tube=%02h led=%b",
                     match_count, unique_good_frames, duplicate_frames, good_frames, bad_frames, dut.tube_status, led);
            $finish;
        end
    end
endmodule
