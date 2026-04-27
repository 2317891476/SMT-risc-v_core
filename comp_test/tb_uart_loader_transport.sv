`timescale 1ns/1ps
`include "define.v"

module tb_uart_loader_transport;
    localparam integer MAX_PAYLOAD_BYTES = 1024;
`ifdef TB_CLK_PERIOD_NS
    localparam integer CLK_PERIOD_NS = `TB_CLK_PERIOD_NS;
`else
    localparam integer CLK_PERIOD_NS = 10;
`endif
`ifdef TB_UART_BIT_NS
    localparam integer UART_BIT_NS = `TB_UART_BIT_NS;
`else
    localparam integer UART_BIT_NS = 40;
`endif
    localparam integer TB_TIMEOUT_NS = 500_000_000;
    localparam [31:0] UART_STATUS_RX_VALID_MASK = 32'h0000_0004;
    localparam [31:0] UART_STATUS_RX_OVERRUN_MASK = 32'h0000_0008;
    localparam [31:0] UART_STATUS_RX_FRAME_ERR_MASK = 32'h0000_0010;

    reg clk;
    reg rstn;
    reg uart_rx;

    reg        m1_req_valid;
    wire       m1_req_ready;
    reg [31:0] m1_req_addr;
    reg        m1_req_write;
    reg [31:0] m1_req_wdata;
    reg [3:0]  m1_req_wen;
    wire       m1_resp_valid;
    wire [31:0] m1_resp_data;

    wire        m0_req_ready;
    wire        m0_resp_valid;
    wire [31:0] m0_resp_data;
    wire        m0_resp_last;
    wire        m2_req_ready;
    wire        m2_resp_valid;
    wire [31:0] m2_resp_data;
    wire [7:0]  tube_status;
    wire        ext_timer_irq;
    wire        ext_external_irq;
    wire        uart_tx;
    wire        debug_uart_tx_byte_valid;
    wire [7:0]  debug_uart_tx_byte;
    wire [7:0]  debug_uart_status_load_count;
    wire [7:0]  debug_uart_tx_store_count;
    wire [127:0] debug_ddr3_m0_bus;

    reg [7:0] payload [0:MAX_PAYLOAD_BYTES-1];
    integer payload_size;
    integer test_seed;
    integer jitter_pct;
    integer byte_gap_bits;
    integer ack_extra_bits;
    string  case_name;
    integer init_idx;
    integer payload_fill_idx;
    integer urand_warmup;
    integer ack_counter;

    integer host_sent;
    integer rx_decoded;
    integer fifo_pushed;
    integer fifo_popped;
    integer mmio_consumed;
    reg [31:0] expected_checksum;
    reg [31:0] actual_checksum;
    integer first_error_idx;
    reg [7:0] first_error_expected;
    reg [7:0] first_error_got;
    reg init_done;
    reg host_done;
    reg consumer_done;
    reg fatal_seen;

    integer last_host_idx;
    reg [7:0] last_host_byte;
    integer last_rxd_idx;
    reg [7:0] last_rxd_byte;
    reg [7:0] last_fifo_head_data;
    integer last_fifo_count;
    integer last_fifo_head;
    integer last_fifo_tail;
    integer last_mmio_idx;
    reg [7:0] last_mmio_byte;

    mem_subsys dut (
        .clk                      (clk),
        .rstn                     (rstn),
        .m0_req_valid             (1'b0),
        .m0_req_ready             (m0_req_ready),
        .m0_req_addr              (32'd0),
        .m0_resp_valid            (m0_resp_valid),
        .m0_resp_data             (m0_resp_data),
        .m0_resp_last             (m0_resp_last),
        .m0_resp_ready            (1'b0),
        .m0_bypass_addr           (32'd0),
        .m0_bypass_data           (),
        .m1_req_valid             (m1_req_valid),
        .m1_req_ready             (m1_req_ready),
        .m1_req_addr              (m1_req_addr),
        .m1_req_write             (m1_req_write),
        .m1_req_wdata             (m1_req_wdata),
        .m1_req_wen               (m1_req_wen),
        .m1_resp_valid            (m1_resp_valid),
        .m1_resp_data             (m1_resp_data),
        .m2_req_valid             (1'b0),
        .m2_req_ready             (m2_req_ready),
        .m2_req_addr              (32'd0),
        .m2_req_write             (1'b0),
        .m2_req_wdata             (32'd0),
        .m2_req_wen               (4'd0),
        .m2_resp_valid            (m2_resp_valid),
        .m2_resp_data             (m2_resp_data),
        .tube_status              (tube_status),
        .ext_irq_src              (1'b0),
        .ext_timer_irq            (ext_timer_irq),
        .ext_external_irq         (ext_external_irq),
        .uart_rx                  (uart_rx),
        .uart_tx                  (uart_tx),
        .debug_uart_tx_byte_valid (debug_uart_tx_byte_valid),
        .debug_uart_tx_byte       (debug_uart_tx_byte),
        .debug_uart_status_load_count(debug_uart_status_load_count),
        .debug_uart_tx_store_count(debug_uart_tx_store_count),
        .debug_store_buffer_empty (1'b1),
        .debug_store_buffer_count_t0(3'd0),
        .debug_store_buffer_count_t1(3'd0),
        .debug_ddr3_m0_bus        (debug_ddr3_m0_bus)
    );

    function automatic [7:0] gen_payload_byte(input integer idx, input integer seed);
        integer mix;
        begin
            mix = ((idx * 17) + (seed * 29) + (idx >> 2) + (idx << 1)) & 255;
            gen_payload_byte = mix[7:0];
        end
    endfunction

    function automatic integer jitter_delay_ns;
        integer span;
        integer delta;
        begin
            span = (UART_BIT_NS * jitter_pct) / 100;
            if (span <= 0) begin
                jitter_delay_ns = UART_BIT_NS;
            end else begin
                delta = $urandom_range(span * 2) - span;
                jitter_delay_ns = UART_BIT_NS + delta;
                if (jitter_delay_ns < 1)
                    jitter_delay_ns = 1;
            end
        end
    endfunction

    function automatic integer random_gap_ns;
        integer gap_bits;
        begin
            if (byte_gap_bits <= 0) begin
                random_gap_ns = 0;
            end else begin
                gap_bits = $urandom_range(byte_gap_bits);
                random_gap_ns = gap_bits * UART_BIT_NS;
            end
        end
    endfunction

    function automatic integer ack_gap_ns;
        integer gap_bits;
        begin
            if (ack_extra_bits <= 0) begin
                ack_gap_ns = 0;
            end else begin
                gap_bits = $urandom_range(ack_extra_bits);
                ack_gap_ns = gap_bits * UART_BIT_NS;
            end
        end
    endfunction

    task automatic send_uart_byte(input integer idx, input [7:0] data);
        integer bit_idx;
        integer bit_ns;
        integer post_gap_ns;
        begin
            last_host_idx = idx;
            last_host_byte = data;
            $display("[HOST] idx=%0d byte=%02x chunk=%0d", idx, data, idx / 4);
            bit_ns = jitter_delay_ns();
            uart_rx = 1'b0;
            #(bit_ns);
            for (bit_idx = 0; bit_idx < 8; bit_idx = bit_idx + 1) begin
                uart_rx = data[bit_idx];
                #(bit_ns);
            end
            uart_rx = 1'b1;
            #(bit_ns);
            post_gap_ns = random_gap_ns();
            if (post_gap_ns > 0)
                #(post_gap_ns);
        end
    endtask

    task automatic mmio_write32(input [31:0] addr, input [31:0] data);
        begin
            @(negedge clk);
            m1_req_addr  <= addr;
            m1_req_write <= 1'b1;
            m1_req_wdata <= data;
            m1_req_wen   <= 4'b1111;
            m1_req_valid <= 1'b1;
            do @(posedge clk); while (!m1_req_ready);
            @(negedge clk);
            m1_req_valid <= 1'b0;
            m1_req_write <= 1'b0;
            m1_req_addr  <= 32'd0;
            m1_req_wdata <= 32'd0;
            m1_req_wen   <= 4'd0;
        end
    endtask

    task automatic mmio_read32(input [31:0] addr, output [31:0] data);
        begin
            @(negedge clk);
            m1_req_addr  <= addr;
            m1_req_write <= 1'b0;
            m1_req_wdata <= 32'd0;
            m1_req_wen   <= 4'd0;
            m1_req_valid <= 1'b1;
            do @(posedge clk); while (!m1_req_ready);
            @(negedge clk);
            m1_req_valid <= 1'b0;
            m1_req_addr  <= 32'd0;
            while (!m1_resp_valid) @(posedge clk);
            data = m1_resp_data;
        end
    endtask

    initial begin
        clk = 1'b0;
        forever #(CLK_PERIOD_NS / 2) clk = ~clk;
    end

    initial begin
        if (!$value$plusargs("PAYLOAD_SIZE=%d", payload_size))
            payload_size = 16;
        if (!$value$plusargs("TEST_SEED=%d", test_seed))
            test_seed = 1;
        if (!$value$plusargs("JITTER_PCT=%d", jitter_pct))
            jitter_pct = 0;
        if (!$value$plusargs("BYTE_GAP_BITS=%d", byte_gap_bits))
            byte_gap_bits = 0;
        if (!$value$plusargs("ACK_EXTRA_BITS=%d", ack_extra_bits))
            ack_extra_bits = 0;
        if (!$value$plusargs("CASE_NAME=%s", case_name))
            case_name = "transport";
        if (payload_size <= 0 || payload_size > MAX_PAYLOAD_BYTES) begin
            $display("[TRANSPORT_TB] invalid payload_size=%0d", payload_size);
            $fatal(1);
        end

        urand_warmup = $urandom(test_seed);
        expected_checksum = 32'd0;
        for (init_idx = 0; init_idx < MAX_PAYLOAD_BYTES; init_idx = init_idx + 1) begin
            payload[init_idx] = 8'd0;
        end
        for (payload_fill_idx = 0; payload_fill_idx < payload_size; payload_fill_idx = payload_fill_idx + 1) begin
            payload[payload_fill_idx] = gen_payload_byte(payload_fill_idx, test_seed);
            expected_checksum = expected_checksum + {24'd0, payload[payload_fill_idx]};
        end

        rstn = 1'b0;
        uart_rx = 1'b1;
        m1_req_valid = 1'b0;
        m1_req_addr = 32'd0;
        m1_req_write = 1'b0;
        m1_req_wdata = 32'd0;
        m1_req_wen = 4'd0;
        host_sent = 0;
        rx_decoded = 0;
        fifo_pushed = 0;
        fifo_popped = 0;
        mmio_consumed = 0;
        actual_checksum = 32'd0;
        first_error_idx = -1;
        first_error_expected = 8'd0;
        first_error_got = 8'd0;
        init_done = 1'b0;
        host_done = 1'b0;
        consumer_done = 1'b0;
        fatal_seen = 1'b0;
        ack_counter = 0;
        last_host_idx = -1;
        last_host_byte = 8'd0;
        last_rxd_idx = -1;
        last_rxd_byte = 8'd0;
        last_fifo_head_data = 8'd0;
        last_fifo_count = 0;
        last_fifo_head = 0;
        last_fifo_tail = 0;
        last_mmio_idx = -1;
        last_mmio_byte = 8'd0;
        repeat (8) @(posedge clk);
        rstn = 1'b1;
    end

    always @(posedge clk) begin
        if (dut.uart_rx_byte_valid) begin
            rx_decoded <= rx_decoded + 1;
            last_rxd_idx <= rx_decoded;
            last_rxd_byte <= dut.uart_rx_byte;
            $display("[RXD ] idx=%0d byte=%02x", rx_decoded, dut.uart_rx_byte);
        end
        if (dut.uart_rx_push_fire || dut.uart_rx_read_fire) begin
            if (dut.uart_rx_push_fire)
                fifo_pushed <= fifo_pushed + 1;
            if (dut.uart_rx_read_fire)
                fifo_popped <= fifo_popped + 1;
            last_fifo_head_data <= dut.uart_rx_head_data;
            last_fifo_count <= dut.uart_rx_count_r;
            last_fifo_head <= dut.uart_rx_head_r;
            last_fifo_tail <= dut.uart_rx_tail_r;
            $display("[FIFO] push=%0b pop=%0b count=%0d head=%0d tail=%0d head_data=%02x push_byte=%02x",
                     dut.uart_rx_push_fire,
                     dut.uart_rx_read_fire,
                     dut.uart_rx_count_r,
                     dut.uart_rx_head_r,
                     dut.uart_rx_tail_r,
                     dut.uart_rx_head_data,
                     dut.uart_rx_byte);
        end
    end

    initial begin : mmio_consumer
        reg [31:0] status_word;
        reg [31:0] data_word;
        reg [7:0]  got_byte;
        wait(rstn == 1'b1);
        repeat (4) @(posedge clk);
        mmio_write32(`UART_CTRL_ADDR, 32'h0000_001F);
        mmio_write32(`UART_CTRL_ADDR, 32'h0000_0003);
        init_done = 1'b1;

        while (mmio_consumed < payload_size) begin
            mmio_read32(`UART_STATUS_ADDR, status_word);
            if ((status_word & UART_STATUS_RX_OVERRUN_MASK) != 0) begin
                $display("[MMIO] RX overrun status=%08x", status_word);
                fatal_seen = 1'b1;
                $fatal(1);
            end
            if ((status_word & UART_STATUS_RX_FRAME_ERR_MASK) != 0) begin
                $display("[MMIO] RX frame error status=%08x", status_word);
                fatal_seen = 1'b1;
                $fatal(1);
            end
            if ((status_word & UART_STATUS_RX_VALID_MASK) != 0) begin
                $display("[MMIO] status=0x%08x rx_valid=1 count=%0d", status_word, dut.uart_rx_count_r);
                mmio_read32(`UART_RXDATA_ADDR, data_word);
                got_byte = data_word[7:0];
                last_mmio_idx = mmio_consumed;
                last_mmio_byte = got_byte;
                actual_checksum = actual_checksum + {24'd0, got_byte};
                $display("[MMIO] idx=%0d byte=%02x checksum=%08x", mmio_consumed, got_byte, actual_checksum);

                if (got_byte !== payload[mmio_consumed]) begin
                    if (first_error_idx < 0) begin
                        first_error_idx = mmio_consumed;
                        first_error_expected = payload[mmio_consumed];
                        first_error_got = got_byte;
                        $display("[FIRST_ERR] idx=%0d exp=%02x got=%02x host_sent=%0d rx_decoded=%0d fifo_pushed=%0d fifo_popped=%0d mmio_consumed=%0d",
                                 first_error_idx,
                                 first_error_expected,
                                 first_error_got,
                                 host_sent,
                                 rx_decoded,
                                 fifo_pushed,
                                 fifo_popped,
                                 mmio_consumed);
                        $display("[FIRST_ERR] host idx=%0d byte=%02x | rxd idx=%0d byte=%02x | fifo count=%0d head=%0d tail=%0d head_data=%02x | mmio idx=%0d byte=%02x",
                                 last_host_idx,
                                 last_host_byte,
                                 last_rxd_idx,
                                 last_rxd_byte,
                                 last_fifo_count,
                                 last_fifo_head,
                                 last_fifo_tail,
                                 last_fifo_head_data,
                                 last_mmio_idx,
                                 last_mmio_byte);
                    end
                end

                if (((mmio_consumed + 1) % 4) == 0)
                    ack_counter = ack_counter + 1;
                mmio_consumed = mmio_consumed + 1;
            end
        end
        consumer_done = 1'b1;
    end

    initial begin : uart_host
        integer idx;
        integer ack_delay;
        integer expected_ack;
        wait(init_done == 1'b1);
        repeat (8) @(posedge clk);
        for (idx = 0; idx < payload_size; idx = idx + 1) begin
            send_uart_byte(idx, payload[idx]);
            host_sent = host_sent + 1;
            if (((idx + 1) % 4) == 0 && (idx + 1) < payload_size) begin
                expected_ack = (idx + 1) / 4;
                wait (ack_counter >= expected_ack);
                ack_delay = ack_gap_ns();
                if (ack_delay > 0)
                    #(ack_delay);
            end
        end
        host_done = 1'b1;
    end

    initial begin : timeout_guard
        #TB_TIMEOUT_NS;
        $display("[TRANSPORT_TB] TIMEOUT case=%0s payload=%0d host=%0d rx=%0d push=%0d pop=%0d mmio=%0d exp_sum=%08x act_sum=%08x first_err=%0d",
                 case_name, payload_size, host_sent, rx_decoded, fifo_pushed, fifo_popped, mmio_consumed,
                 expected_checksum, actual_checksum, first_error_idx);
        fatal_seen = 1'b1;
        $fatal(1);
    end

    always @(posedge clk) begin
        if (rstn && host_done && consumer_done) begin
            if (first_error_idx >= 0) begin
                $display("[TRANSPORT_TB] FAIL case=%0s first_err=%0d exp=%02x got=%02x", case_name, first_error_idx, first_error_expected, first_error_got);
                fatal_seen <= 1'b1;
                $fatal(1);
            end
            if (host_sent != payload_size || rx_decoded != payload_size || fifo_pushed != payload_size || fifo_popped != payload_size || mmio_consumed != payload_size) begin
                $display("[TRANSPORT_TB] FAIL case=%0s count_mismatch payload=%0d host=%0d rx=%0d push=%0d pop=%0d mmio=%0d",
                         case_name, payload_size, host_sent, rx_decoded, fifo_pushed, fifo_popped, mmio_consumed);
                fatal_seen <= 1'b1;
                $fatal(1);
            end
            if (actual_checksum != expected_checksum) begin
                $display("[TRANSPORT_TB] FAIL case=%0s checksum exp=%08x got=%08x", case_name, expected_checksum, actual_checksum);
                fatal_seen <= 1'b1;
                $fatal(1);
            end
            $display("[TRANSPORT_TB] PASS case=%0s payload=%0d host=%0d rx=%0d push=%0d pop=%0d mmio=%0d checksum=%08x jitter_pct=%0d byte_gap_bits=%0d ack_extra_bits=%0d",
                     case_name, payload_size, host_sent, rx_decoded, fifo_pushed, fifo_popped, mmio_consumed,
                     actual_checksum, jitter_pct, byte_gap_bits, ack_extra_bits);
            $finish;
        end
    end
endmodule
