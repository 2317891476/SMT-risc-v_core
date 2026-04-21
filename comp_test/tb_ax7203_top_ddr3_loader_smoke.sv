`timescale 1ns/1ps

module tb_ax7203_top_ddr3_loader_smoke;
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
`elsif FULL_GATE_FAST_UART
    localparam integer UART_BIT_NS = 160;
`else
    localparam integer UART_BIT_NS = 8680;
`endif
`ifdef TB_SHORT_TIMEOUT_NS
    localparam integer TB_TIMEOUT_NS = `TB_SHORT_TIMEOUT_NS;
`else
    localparam integer TB_TIMEOUT_NS = 80_000_000;
`endif
    localparam integer MAX_PAYLOAD_BYTES = 16384;
    localparam [111:0] EXEC_PASS_TOKEN = 112'h4444523320455845432050415353; // DDR3 EXEC PASS
    localparam [7:0] LOADER_ACK_BYTE = 8'h06;
    localparam [7:0] LOADER_BLOCK_ACK_BYTE = 8'h17;
    localparam [7:0] LOADER_BLOCK_NACK_BYTE = 8'h15;
    localparam integer BLOCK_CHECKSUM_BYTES = 64;
    localparam [7:0] BEACON_SOF = 8'hA5;
    localparam [7:0] EVT_READY = 8'h01;
    localparam [7:0] EVT_LOAD_START = 8'h02;
    localparam [7:0] EVT_BLOCK_ACK = 8'h11;
    localparam [7:0] EVT_BLOCK_NACK = 8'h12;
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
    localparam [7:0] EVT_READ_OK = 8'h21;
    localparam [7:0] EVT_LOAD_OK = 8'h22;
    localparam [7:0] EVT_JUMP = 8'h23;
    localparam [7:0] EVT_CAL_FAIL = 8'hE0;
    localparam [7:0] EVT_BAD_MAGIC = 8'hE1;
    localparam [7:0] EVT_CHECKSUM_FAIL = 8'hE2;
    localparam [7:0] EVT_READBACK_FAIL = 8'hE3;
    localparam [7:0] EVT_READBACK_BLOCK_FAIL = 8'hE4;
    localparam [7:0] EVT_RX_OVERRUN = 8'hE5;
    localparam [7:0] EVT_RX_FRAME_ERR = 8'hE6;
    localparam [7:0] EVT_DRAIN_TIMEOUT = 8'hE7;
    localparam [7:0] EVT_SIZE_TOO_BIG = 8'hE8;
    localparam [7:0] EVT_SUMMARY = 8'hF0;
    localparam integer BEACON_SELFTEST_EVT_COUNT = 14;
    localparam [7:0] LOADER_SUM_READY = 8'h01;
    localparam [7:0] LOADER_SUM_LOAD_START = 8'h02;
    localparam [7:0] LOADER_SUM_READ_OK = 8'h04;
    localparam [7:0] LOADER_SUM_LOAD_OK = 8'h08;
    localparam [7:0] LOADER_SUM_JUMP = 8'h10;
    localparam [7:0] LOADER_SUM_ANY_BAD = 8'h80;
    localparam [7:0] EARLY_AUDIT_SUM_READY = 8'h01;
    localparam [7:0] EARLY_AUDIT_SUM_HDR_MAGIC_OK = 8'h02;
    localparam [7:0] EARLY_AUDIT_SUM_LOAD_START = 8'h04;
    localparam [7:0] EARLY_AUDIT_SUM_FIRST_BLOCK_ACK = 8'h08;
`ifdef FULL_GATE_FAST_UART
    localparam integer DEFAULT_FAST_UART_INJECT = 0;
    localparam integer DEFAULT_INITIAL_HEADER_WAIT_BITS = 8;
    localparam integer DEFAULT_INITIAL_PAYLOAD_WAIT_BITS = 8;
    localparam integer DEFAULT_INTER_U32_GAP_BITS = 2;
    localparam integer DEFAULT_CHUNK_ACK_GAP_BITS = 1;
    localparam integer DEFAULT_BLOCK_DONE_GAP_BITS = 1;
`else
    localparam integer DEFAULT_FAST_UART_INJECT = 0;
    localparam integer DEFAULT_INITIAL_HEADER_WAIT_BITS = 80;
    localparam integer DEFAULT_INITIAL_PAYLOAD_WAIT_BITS = 80;
    localparam integer DEFAULT_INTER_U32_GAP_BITS = 64;
    localparam integer DEFAULT_CHUNK_ACK_GAP_BITS = 4;
    localparam integer DEFAULT_BLOCK_DONE_GAP_BITS = 8;
`endif

    reg [7:0] payload [0:MAX_PAYLOAD_BYTES-1];
    integer payload_size;
    integer payload_checksum;
    integer payload_idx;
    integer sent_header;
    integer sent_payload;
    integer fast_uart_inject;
    integer initial_header_wait_bits;
    integer initial_payload_wait_bits;
    integer inter_u32_gap_bits;
    integer chunk_ack_gap_bits;
    integer block_done_gap_bits;
    integer full_gate_prefix_enable;
    integer full_gate_prefix_block_ack_target;
    integer early_audit_enable;
    integer early_audit_bad_magic_byte;
    integer beacon_selftest_enable;
    integer uart_byte_count;
    integer passthrough_byte_count;
    integer expect_exec_pass;
    integer loader_ack_count;
    integer block_ack_count;
    integer block_nack_count;
    integer beacon_block_ack_count;
    integer beacon_block_nack_count;
    integer beacon_max_block_ack_arg;
    integer beacon_good_frames;
    integer beacon_bad_frames;
    reg saw_ready;
    reg saw_load_start;
    reg saw_read_ok;
    reg saw_load_ok;
    reg saw_jump;
    reg saw_summary;
    reg saw_exec_pass;
    reg saw_bad;
    reg saw_hdr_b0;
    reg saw_hdr_b1;
    reg saw_hdr_b2;
    reg saw_hdr_b3;
    reg saw_hdr_magic_ok;
    reg [7:0] summary_mask;
    reg [7:0] hdr_b0_rx;
    reg [7:0] hdr_b1_rx;
    reg [7:0] hdr_b2_rx;
    reg [7:0] hdr_b3_rx;
    integer bad_magic_byte_idx;
    reg [255:0] seen_seq_bitmap;
    reg [7:0] beacon_buf [0:4];
    reg [7:0] calc_chk;
    reg [7:0] injected_uart_byte;
    integer beacon_idx;
    reg beacon_collecting;
    reg [127:0] shift128;
    integer beacon_selftest_match_count;
    reg beacon_selftest_bad;
    event payload_ack_event;

    function automatic [7:0] beacon_selftest_expected_type(input integer idx);
        begin
            case (idx)
                0: beacon_selftest_expected_type = EVT_READY;
                1: beacon_selftest_expected_type = EVT_IDLE_OK;
                2: beacon_selftest_expected_type = EVT_TRAIN_START;
                3: beacon_selftest_expected_type = EVT_TRAIN_DONE;
                4: beacon_selftest_expected_type = EVT_FLUSH_DONE;
                5: beacon_selftest_expected_type = EVT_HEADER_ENTER;
                6: beacon_selftest_expected_type = EVT_HDR_B0_RX;
                7: beacon_selftest_expected_type = EVT_HDR_B1_RX;
                8: beacon_selftest_expected_type = EVT_HDR_B2_RX;
                9: beacon_selftest_expected_type = EVT_HDR_B3_RX;
                10: beacon_selftest_expected_type = EVT_HDR_MAGIC_OK;
                11: beacon_selftest_expected_type = EVT_LOAD_START;
                12: beacon_selftest_expected_type = EVT_BLOCK_ACK;
                13: beacon_selftest_expected_type = EVT_SUMMARY;
                default: beacon_selftest_expected_type = 8'hFF;
            endcase
        end
    endfunction

    function automatic [7:0] beacon_selftest_expected_arg(input integer idx);
        begin
            case (idx)
                0: beacon_selftest_expected_arg = 8'hA1;
                1: beacon_selftest_expected_arg = 8'hB2;
                2: beacon_selftest_expected_arg = 8'hC3;
                3: beacon_selftest_expected_arg = 8'h14;
                4: beacon_selftest_expected_arg = 8'h05;
                5: beacon_selftest_expected_arg = 8'hD6;
                6: beacon_selftest_expected_arg = 8'h42;
                7: beacon_selftest_expected_arg = 8'h4D;
                8: beacon_selftest_expected_arg = 8'h4B;
                9: beacon_selftest_expected_arg = 8'h31;
                10: beacon_selftest_expected_arg = 8'hE7;
                11: beacon_selftest_expected_arg = 8'hF8;
                12: beacon_selftest_expected_arg = 8'h00;
                13: beacon_selftest_expected_arg = 8'h0F;
                default: beacon_selftest_expected_arg = 8'hFF;
            endcase
        end
    endfunction

    wire core_uart_tx_start = dut.core_uart_byte_valid_dbg;
    wire [7:0] core_uart_tx_byte = dut.core_uart_byte_dbg;
    wire [383:0] fetch_dbg = dut.core_ddr3_fetch_debug_bus;
    wire [7:0] dbg_m0_req_count       = fetch_dbg[7:0];
    wire [7:0] dbg_m0_accept_count    = fetch_dbg[15:8];
    wire [7:0] dbg_m0_resp_count      = fetch_dbg[23:16];
    wire [7:0] dbg_m0_last_count      = fetch_dbg[31:24];
    wire [31:0] dbg_m0_last_req_addr  = fetch_dbg[63:32];
    wire [31:0] dbg_m0_last_resp_data = fetch_dbg[95:64];
    wire [7:0] dbg_ic_high_miss_count = fetch_dbg[103:96];
    wire [7:0] dbg_ic_mem_req_count   = fetch_dbg[111:104];
    wire [7:0] dbg_ic_mem_resp_count  = fetch_dbg[119:112];
    wire [7:0] dbg_ic_cpu_resp_count  = fetch_dbg[127:120];
    wire [31:0] dbg_fetch_pc_pending  = fetch_dbg[159:128];
    wire [31:0] dbg_fetch_pc_out      = fetch_dbg[191:160];
    wire [7:0] dbg_if_flags           = fetch_dbg[199:192];
    wire [7:0] dbg_m0_flags           = fetch_dbg[207:200];
    wire [7:0] dbg_ic_state_flags     = fetch_dbg[215:208];
    wire [7:0] dbg_pipe_flags         = fetch_dbg[263:256];
    wire [7:0] dbg_if_valid_count     = fetch_dbg[271:264];
    wire [7:0] dbg_fb_pop_count       = fetch_dbg[279:272];
    wire [7:0] dbg_dec0_count         = fetch_dbg[287:280];
    wire [7:0] dbg_disp0_count        = fetch_dbg[295:288];
    wire [7:0] dbg_retire_count       = fetch_dbg[303:296];
    wire [7:0] dbg_m1_req_count       = fetch_dbg[311:304];
    wire [7:0] dbg_m1_resp_count      = fetch_dbg[319:312];
    wire [7:0] dbg_uart_flags         = fetch_dbg[335:328];
    wire [7:0] dbg_uart_tx_write_count= fetch_dbg[327:320];

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

    task automatic send_uart_byte(input [7:0] data);
        integer bit_idx;
        begin
            if (fast_uart_inject != 0) begin
                injected_uart_byte = data;
                @(negedge dut.core_clk_dbg);
                force dut.u_adam_riscv.gen_mem_subsys.u_mem_subsys.uart_rx_byte_valid = 1'b1;
                force dut.u_adam_riscv.gen_mem_subsys.u_mem_subsys.uart_rx_byte = injected_uart_byte;
                force dut.u_adam_riscv.gen_mem_subsys.u_mem_subsys.uart_rx_frame_error = 1'b0;
                @(posedge dut.core_clk_dbg);
                @(negedge dut.core_clk_dbg);
                release dut.u_adam_riscv.gen_mem_subsys.u_mem_subsys.uart_rx_byte_valid;
                release dut.u_adam_riscv.gen_mem_subsys.u_mem_subsys.uart_rx_byte;
                release dut.u_adam_riscv.gen_mem_subsys.u_mem_subsys.uart_rx_frame_error;
                while (dut.u_adam_riscv.gen_mem_subsys.u_mem_subsys.uart_rx_count_r > 2)
                    @(posedge dut.core_clk_dbg);
            end else begin
                uart_rx = 1'b0;
                #(UART_BIT_NS);
                for (bit_idx = 0; bit_idx < 8; bit_idx = bit_idx + 1) begin
                    uart_rx = data[bit_idx];
                    #(UART_BIT_NS);
                end
                uart_rx = 1'b1;
                #(UART_BIT_NS);
            end
        end
    endtask

    task automatic send_u32_le(input [31:0] data);
        begin
            send_uart_byte(data[7:0]);
            #(UART_BIT_NS * inter_u32_gap_bits);
            send_uart_byte(data[15:8]);
            #(UART_BIT_NS * inter_u32_gap_bits);
            send_uart_byte(data[23:16]);
            #(UART_BIT_NS * inter_u32_gap_bits);
            send_uart_byte(data[31:24]);
            #(UART_BIT_NS * inter_u32_gap_bits);
        end
    endtask

    task automatic send_header_frame;
        reg [31:0] magic_word;
        integer train_idx;
        begin
            magic_word = 32'h314B4D42;
            if (early_audit_enable != 0) begin
                for (train_idx = 0; train_idx < 16; train_idx = train_idx + 1) begin
                    send_uart_byte(8'h55);
                    #(UART_BIT_NS * inter_u32_gap_bits);
                end
                case (early_audit_bad_magic_byte)
                    0: magic_word[7:0] = magic_word[7:0] ^ 8'hFF;
                    1: magic_word[15:8] = magic_word[15:8] ^ 8'hFF;
                    2: magic_word[23:16] = magic_word[23:16] ^ 8'hFF;
                    3: magic_word[31:24] = magic_word[31:24] ^ 8'hFF;
                    default: begin end
                endcase
            end
            send_u32_le(magic_word);         // "BMK1" little-endian
            send_u32_le(32'h80000000);       // load address
            send_u32_le(32'h80000000);       // entry
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

    task automatic send_payload_block;
        integer block_start_idx;
        integer block_end_idx;
        integer block_checksum;
        integer block_log_start;
        integer prev_loader_ack_count;
        integer prev_block_ack_count;
        integer prev_block_nack_count;
        begin
            block_start_idx = payload_idx;
            block_end_idx = payload_idx + BLOCK_CHECKSUM_BYTES;
            if (block_end_idx > payload_size)
                block_end_idx = payload_size;
            block_log_start = block_start_idx;
            block_checksum = 0;

            while (payload_idx < block_end_idx) begin
                if (full_gate_prefix_enable == 0)
                    $display("[AX7203_DDR3_LOADER_TB] send chunk start_idx=%0d", payload_idx);
                prev_loader_ack_count = loader_ack_count;
                send_payload_chunk();
                wait (loader_ack_count != prev_loader_ack_count);
                #(UART_BIT_NS * chunk_ack_gap_bits);
            end

            for (block_start_idx = block_start_idx; block_start_idx < block_end_idx; block_start_idx = block_start_idx + 1)
                block_checksum = (block_checksum + payload[block_start_idx]) & 32'hFFFF_FFFF;

            if (full_gate_prefix_enable == 0)
                $display("[AX7203_DDR3_LOADER_TB] send block checksum block_start=%0d block_end=%0d checksum=%08x", block_log_start, block_end_idx, block_checksum);
            prev_loader_ack_count = loader_ack_count;
            prev_block_ack_count = block_ack_count;
            prev_block_nack_count = block_nack_count;
            send_u32_le(block_checksum[31:0]);
            wait (loader_ack_count != prev_loader_ack_count);
            #(UART_BIT_NS * chunk_ack_gap_bits);
            wait ((block_ack_count != prev_block_ack_count) || (block_nack_count != prev_block_nack_count));
            if (block_nack_count != prev_block_nack_count) begin
                $display("[AX7203_DDR3_LOADER] unexpected block NACK payload_idx=%0d", payload_idx);
                $fatal(1);
            end
            #(UART_BIT_NS * block_done_gap_bits);
        end
    endtask

    task automatic handle_beacon_event(input [7:0] seq, input [7:0] evt_type, input [7:0] evt_arg);
        begin
            if (seen_seq_bitmap[seq]) begin
                $display("[AX7203_DDR3_LOADER_EVT] duplicate seq=%02x type=%02x arg=%02x", seq, evt_type, evt_arg);
                if (beacon_selftest_enable != 0)
                    beacon_selftest_bad = 1'b1;
            end else begin
                seen_seq_bitmap[seq] = 1'b1;
                $display("[AX7203_DDR3_LOADER_EVT] seq=%02x type=%02x arg=%02x", seq, evt_type, evt_arg);
                if (beacon_selftest_enable != 0) begin
                    if (beacon_selftest_match_count >= BEACON_SELFTEST_EVT_COUNT) begin
                        beacon_selftest_bad = 1'b1;
                    end else if ((evt_type != beacon_selftest_expected_type(beacon_selftest_match_count)) ||
                                 (evt_arg != beacon_selftest_expected_arg(beacon_selftest_match_count))) begin
                        beacon_selftest_bad = 1'b1;
                    end else begin
                        beacon_selftest_match_count = beacon_selftest_match_count + 1;
                    end
                end
                case (evt_type)
                    EVT_READY: saw_ready = 1'b1;
                    EVT_LOAD_START: saw_load_start = 1'b1;
                    EVT_BLOCK_ACK: begin
                        beacon_block_ack_count = beacon_block_ack_count + 1;
                        if ((beacon_max_block_ack_arg < 0) || (evt_arg > beacon_max_block_ack_arg))
                            beacon_max_block_ack_arg = evt_arg;
                    end
                    EVT_BLOCK_NACK: begin
                        beacon_block_nack_count = beacon_block_nack_count + 1;
                    end
                    EVT_HDR_B0_RX: begin
                        saw_hdr_b0 = 1'b1;
                        hdr_b0_rx = evt_arg;
                    end
                    EVT_HDR_B1_RX: begin
                        saw_hdr_b1 = 1'b1;
                        hdr_b1_rx = evt_arg;
                    end
                    EVT_HDR_B2_RX: begin
                        saw_hdr_b2 = 1'b1;
                        hdr_b2_rx = evt_arg;
                    end
                    EVT_HDR_B3_RX: begin
                        saw_hdr_b3 = 1'b1;
                        hdr_b3_rx = evt_arg;
                    end
                    EVT_HDR_MAGIC_OK: saw_hdr_magic_ok = 1'b1;
                    EVT_READ_OK: saw_read_ok = 1'b1;
                    EVT_LOAD_OK: saw_load_ok = 1'b1;
                    EVT_JUMP: saw_jump = 1'b1;
                    EVT_SUMMARY: begin
                        saw_summary = 1'b1;
                        summary_mask = evt_arg;
                    end
                    EVT_CAL_FAIL,
                    EVT_CHECKSUM_FAIL,
                    EVT_READBACK_FAIL,
                    EVT_READBACK_BLOCK_FAIL,
                    EVT_RX_OVERRUN,
                    EVT_RX_FRAME_ERR,
                    EVT_DRAIN_TIMEOUT,
                    EVT_SIZE_TOO_BIG: saw_bad = 1'b1;
                    EVT_BAD_MAGIC: begin
                        saw_bad = 1'b1;
                        bad_magic_byte_idx = evt_arg;
                    end
                    default: begin end
                endcase
            end
        end
    endtask

    task automatic handle_passthrough_byte(input [7:0] data);
        begin
            passthrough_byte_count = passthrough_byte_count + 1;
            shift128 = {shift128[119:0], data};
            if (data >= 8'h20 && data <= 8'h7e)
                $write("%c", data);
            else if (data == 8'h0d)
                $write("<CR>");
            else if (data == 8'h0a)
                $write("<LF>\n");

            if ((data == LOADER_ACK_BYTE) && (sent_payload != 0)) begin
                loader_ack_count = loader_ack_count + 1;
                -> payload_ack_event;
            end
            if ((data == LOADER_BLOCK_ACK_BYTE) && (sent_payload != 0))
                block_ack_count = block_ack_count + 1;
            if ((data == LOADER_BLOCK_NACK_BYTE) && (sent_payload != 0))
                block_nack_count = block_nack_count + 1;
            if ({shift128[103:0], data} == EXEC_PASS_TOKEN)
                saw_exec_pass = 1'b1;
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
        if (!$value$plusargs("EXPECT_EXEC_PASS=%d", expect_exec_pass)) expect_exec_pass = 1;
        if (!$value$plusargs("FAST_UART_INJECT=%d", fast_uart_inject)) fast_uart_inject = DEFAULT_FAST_UART_INJECT;
        if (!$value$plusargs("INITIAL_HEADER_WAIT_BITS=%d", initial_header_wait_bits)) initial_header_wait_bits = DEFAULT_INITIAL_HEADER_WAIT_BITS;
        if (!$value$plusargs("INITIAL_PAYLOAD_WAIT_BITS=%d", initial_payload_wait_bits)) initial_payload_wait_bits = DEFAULT_INITIAL_PAYLOAD_WAIT_BITS;
        if (!$value$plusargs("INTER_U32_GAP_BITS=%d", inter_u32_gap_bits)) inter_u32_gap_bits = DEFAULT_INTER_U32_GAP_BITS;
        if (!$value$plusargs("CHUNK_ACK_GAP_BITS=%d", chunk_ack_gap_bits)) chunk_ack_gap_bits = DEFAULT_CHUNK_ACK_GAP_BITS;
        if (!$value$plusargs("BLOCK_DONE_GAP_BITS=%d", block_done_gap_bits)) block_done_gap_bits = DEFAULT_BLOCK_DONE_GAP_BITS;
        if (!$value$plusargs("FULL_GATE_PREFIX_ENABLE=%d", full_gate_prefix_enable)) full_gate_prefix_enable = 0;
        if (!$value$plusargs("FULL_GATE_PREFIX_BLOCK_ACK_TARGET=%d", full_gate_prefix_block_ack_target)) full_gate_prefix_block_ack_target = 16;
        if (!$value$plusargs("EARLY_AUDIT_ENABLE=%d", early_audit_enable)) early_audit_enable = 0;
        if (!$value$plusargs("EARLY_AUDIT_BAD_MAGIC_BYTE=%d", early_audit_bad_magic_byte)) early_audit_bad_magic_byte = -1;
        if (!$value$plusargs("BEACON_SELFTEST_ENABLE=%d", beacon_selftest_enable)) beacon_selftest_enable = 0;
        if ((beacon_selftest_enable == 0) && (payload_size <= 0 || payload_size > MAX_PAYLOAD_BYTES)) begin
            $display("[AX7203_DDR3_LOADER] bad payload_size=%0d", payload_size);
            $fatal(1);
        end
        $readmemh("ddr3_loader_payload.hex", payload);

        sys_rst_n = 1'b0;
        uart_rx = 1'b1;
        sent_header = 0;
        sent_payload = 0;
        uart_byte_count = 0;
        passthrough_byte_count = 0;
        loader_ack_count = 0;
        block_ack_count = 0;
        block_nack_count = 0;
        beacon_block_ack_count = 0;
        beacon_block_nack_count = 0;
        beacon_max_block_ack_arg = -1;
        beacon_good_frames = 0;
        beacon_bad_frames = 0;
        saw_ready = 1'b0;
        saw_load_start = 1'b0;
        saw_read_ok = 1'b0;
        saw_load_ok = 1'b0;
        saw_jump = 1'b0;
        saw_summary = 1'b0;
        saw_exec_pass = 1'b0;
        saw_bad = 1'b0;
        saw_hdr_b0 = 1'b0;
        saw_hdr_b1 = 1'b0;
        saw_hdr_b2 = 1'b0;
        saw_hdr_b3 = 1'b0;
        saw_hdr_magic_ok = 1'b0;
        summary_mask = 8'd0;
        hdr_b0_rx = 8'd0;
        hdr_b1_rx = 8'd0;
        hdr_b2_rx = 8'd0;
        hdr_b3_rx = 8'd0;
        bad_magic_byte_idx = -1;
        seen_seq_bitmap = 256'd0;
        beacon_idx = 0;
        beacon_collecting = 1'b0;
        shift128 = 128'd0;
        beacon_selftest_match_count = 0;
        beacon_selftest_bad = 1'b0;
        #100;
        sys_rst_n = 1'b1;
    end

    initial begin : uart_host_driver
        wait(sys_rst_n == 1'b1);
        wait(saw_ready == 1'b1);
        if (beacon_selftest_enable != 0) begin
            wait(saw_summary == 1'b1);
        end else begin
        #(UART_BIT_NS * initial_header_wait_bits);
        $display("[AX7203_DDR3_LOADER_TB] send header");
        sent_header = 1;
        send_header_frame();
        if ((early_audit_enable != 0) && (early_audit_bad_magic_byte >= 0))
            wait(saw_summary == 1'b1);
        else
            wait(saw_load_start == 1'b1);
        #(UART_BIT_NS * initial_payload_wait_bits);
        if (!((early_audit_enable != 0) && (early_audit_bad_magic_byte >= 0))) begin
            sent_payload = 1;
            payload_idx = 0;
            while (payload_idx < payload_size &&
                   ((full_gate_prefix_enable == 0) || (beacon_block_ack_count < full_gate_prefix_block_ack_target)))
                send_payload_block();
        end
        end
    end

    always @(posedge core_uart_tx_start) begin
        uart_byte_count = uart_byte_count + 1;
        if (!beacon_collecting && (core_uart_tx_byte == BEACON_SOF)) begin
            beacon_collecting = 1'b1;
            beacon_idx = 1;
            beacon_buf[0] = core_uart_tx_byte;
        end else if (beacon_collecting) begin
            beacon_buf[beacon_idx] = core_uart_tx_byte;
            if (beacon_idx == 4) begin
                calc_chk = beacon_buf[0] ^ beacon_buf[1] ^ beacon_buf[2] ^ beacon_buf[3];
                if ((beacon_buf[0] == BEACON_SOF) && (calc_chk == core_uart_tx_byte)) begin
                    beacon_good_frames = beacon_good_frames + 1;
                    handle_beacon_event(beacon_buf[1], beacon_buf[2], beacon_buf[3]);
                end else begin
                    beacon_bad_frames = beacon_bad_frames + 1;
                    if (beacon_selftest_enable != 0)
                        beacon_selftest_bad = 1'b1;
                    $display("[AX7203_DDR3_LOADER_EVT] bad frame bytes=%02x %02x %02x %02x %02x",
                             beacon_buf[0], beacon_buf[1], beacon_buf[2], beacon_buf[3], core_uart_tx_byte);
                end
                beacon_collecting = 1'b0;
                beacon_idx = 0;
            end else begin
                beacon_idx = beacon_idx + 1;
            end
        end else begin
            handle_passthrough_byte(core_uart_tx_byte);
        end
    end

    initial begin : timeout_guard
        #TB_TIMEOUT_NS;
        $display("[AX7203_DDR3_LOADER] TIMEOUT ready=%0b hdr=%0b%0b%0b%0b hdr_magic_ok=%0b hdr_bytes=%02x,%02x,%02x,%02x bad_magic_idx=%0d load_start=%0b read_ok=%0b load_ok=%0b jump=%0b summary=%0b mask=%02x bad=%0b exec_pass=%0b sent_header=%0d sent_payload=%0d payload_idx=%0d uart_bytes=%0d pass_bytes=%0d block_ack=%0d block_nack=%0d beacon_block_ack=%0d beacon_block_nack=%0d beacon_max_ack=%0d prefix_enable=%0d prefix_target=%0d early_audit=%0d early_bad_byte=%0d beacon_good=%0d beacon_bad=%0d tube=%02h led=%b",
                 saw_ready, saw_hdr_b0, saw_hdr_b1, saw_hdr_b2, saw_hdr_b3, saw_hdr_magic_ok, hdr_b0_rx, hdr_b1_rx, hdr_b2_rx, hdr_b3_rx, bad_magic_byte_idx, saw_load_start, saw_read_ok, saw_load_ok, saw_jump, saw_summary, summary_mask, saw_bad, saw_exec_pass,
                 sent_header, sent_payload, payload_idx, uart_byte_count, passthrough_byte_count, block_ack_count, block_nack_count,
                 beacon_block_ack_count, beacon_block_nack_count, beacon_max_block_ack_arg, full_gate_prefix_enable, full_gate_prefix_block_ack_target,
                 early_audit_enable, early_audit_bad_magic_byte, beacon_good_frames, beacon_bad_frames, dut.tube_status, led);
        $display("[AX7203_DDR3_LOADER] DDR3 core_req_v=%0b core_req_r=%0b addr=%08h wr=%0b resp_v=%0b arb_state=%0d owner=%0d req_v=%0b req_r=%0b m0r=%0b m1r=%0b m0rv=%0b m1rv=%0b",
                 dut.core_ddr3_req_valid,
                 dut.core_ddr3_req_ready,
                 dut.core_ddr3_req_addr,
                 dut.core_ddr3_req_write,
                 dut.core_ddr3_resp_valid,
                 dut.u_adam_riscv.gen_mem_subsys.u_mem_subsys.ddr3_arb_state,
                 dut.u_adam_riscv.gen_mem_subsys.u_mem_subsys.ddr3_owner_r,
                 dut.u_adam_riscv.gen_mem_subsys.u_mem_subsys.ddr3_req_valid,
                 dut.u_adam_riscv.gen_mem_subsys.u_mem_subsys.ddr3_req_ready,
                 dut.u_adam_riscv.gen_mem_subsys.u_mem_subsys.m0_ddr3_req_ready,
                 dut.u_adam_riscv.gen_mem_subsys.u_mem_subsys.m1_ddr3_req_ready,
                 dut.u_adam_riscv.gen_mem_subsys.u_mem_subsys.m0_ddr3_resp_valid,
                 dut.u_adam_riscv.gen_mem_subsys.u_mem_subsys.m1_ddr3_resp_valid);
        $display("[AX7203_DDR3_LOADER] FETCH pc_out=%08h pc_pending=%08h if_flags=%02h ic_state=%02h m0_flags=%02h pipe=%02h if_v=%0d fb=%0d dec=%0d disp=%0d retire=%0d",
                 dbg_fetch_pc_out, dbg_fetch_pc_pending, dbg_if_flags, dbg_ic_state_flags, dbg_m0_flags, dbg_pipe_flags,
                 dbg_if_valid_count, dbg_fb_pop_count, dbg_dec0_count, dbg_disp0_count, dbg_retire_count);
        $display("[AX7203_DDR3_LOADER] FETCH m0_req=%0d m0_acc=%0d m0_resp=%0d m0_last=%0d last_addr=%08h last_data=%08h ic_high_miss=%0d ic_mem_req=%0d ic_mem_resp=%0d ic_cpu_resp=%0d",
                 dbg_m0_req_count, dbg_m0_accept_count, dbg_m0_resp_count, dbg_m0_last_count,
                 dbg_m0_last_req_addr, dbg_m0_last_resp_data,
                 dbg_ic_high_miss_count, dbg_ic_mem_req_count, dbg_ic_mem_resp_count, dbg_ic_cpu_resp_count);
        $display("[AX7203_DDR3_LOADER] FETCH aux m1_req=%0d m1_resp=%0d uart_flags=%02h uart_tx_writes=%0d raw_bus=%096h",
                 dbg_m1_req_count, dbg_m1_resp_count, dbg_uart_flags, dbg_uart_tx_write_count, fetch_dbg);
        $display("[AX7203_DDR3_LOADER] SELFTEST enable=%0d match_count=%0d bad=%0b",
                 beacon_selftest_enable, beacon_selftest_match_count, beacon_selftest_bad);
        $fatal(1);
    end

    always @(posedge sys_clk_p) begin
        if (dut.tube_status == 8'h04)
            saw_exec_pass = 1'b1;
        if (beacon_selftest_enable != 0) begin
            if (sys_rst_n && saw_summary && (summary_mask == 8'h0F) &&
                (beacon_selftest_match_count == BEACON_SELFTEST_EVT_COUNT) &&
                (beacon_good_frames == BEACON_SELFTEST_EVT_COUNT) &&
                (beacon_bad_frames == 0) && !beacon_selftest_bad) begin
                $display("[AX7203_DDR3_LOADER] PASS beacon_selftest=1 ready=%0b summary=%0b mask=%02h match_count=%0d beacon_good=%0d beacon_bad=%0d tube=%02h led=%b",
                         saw_ready, saw_summary, summary_mask, beacon_selftest_match_count, beacon_good_frames, beacon_bad_frames,
                         dut.tube_status, led);
                $finish;
            end
        end else if (early_audit_enable != 0) begin
            if (sys_rst_n && (early_audit_bad_magic_byte >= 0)) begin
                if (saw_ready && saw_summary && saw_bad &&
                    (bad_magic_byte_idx == early_audit_bad_magic_byte) &&
                    ((summary_mask & LOADER_SUM_ANY_BAD) != 0)) begin
                    $display("[AX7203_DDR3_LOADER] PASS early_audit=1 bad_magic_byte=%0d ready=%0b hdr=%0b%0b%0b%0b summary=%0b mask=%02h bad=%0b bad_magic_idx=%0d beacon_good=%0d beacon_bad=%0d tube=%02h led=%b",
                             early_audit_bad_magic_byte, saw_ready, saw_hdr_b0, saw_hdr_b1, saw_hdr_b2, saw_hdr_b3, saw_summary, summary_mask, saw_bad, bad_magic_byte_idx,
                             beacon_good_frames, beacon_bad_frames, dut.tube_status, led);
                    $finish;
                end
            end else if (sys_rst_n && saw_ready && saw_hdr_b0 && saw_hdr_b1 && saw_hdr_b2 && saw_hdr_b3 &&
                         saw_hdr_magic_ok && saw_load_start &&
                         (beacon_block_ack_count >= 1) && (beacon_max_block_ack_arg >= 0) &&
                         (beacon_block_nack_count == 0) && saw_summary &&
                         ((summary_mask & (EARLY_AUDIT_SUM_READY | EARLY_AUDIT_SUM_HDR_MAGIC_OK | EARLY_AUDIT_SUM_LOAD_START | EARLY_AUDIT_SUM_FIRST_BLOCK_ACK)) ==
                          (EARLY_AUDIT_SUM_READY | EARLY_AUDIT_SUM_HDR_MAGIC_OK | EARLY_AUDIT_SUM_LOAD_START | EARLY_AUDIT_SUM_FIRST_BLOCK_ACK)) &&
                         ((summary_mask & LOADER_SUM_ANY_BAD) == 0) && !saw_bad) begin
                $display("[AX7203_DDR3_LOADER] PASS early_audit=1 ready=%0b hdr_magic_ok=%0b load_start=%0b block_ack=%0d summary=%0b mask=%02h bad=%0b hdr_bytes=%02x,%02x,%02x,%02x beacon_good=%0d beacon_bad=%0d tube=%02h led=%b",
                         saw_ready, saw_hdr_magic_ok, saw_load_start, beacon_block_ack_count, saw_summary, summary_mask, saw_bad,
                         hdr_b0_rx, hdr_b1_rx, hdr_b2_rx, hdr_b3_rx, beacon_good_frames, beacon_bad_frames, dut.tube_status, led);
                $finish;
            end
        end else if (full_gate_prefix_enable != 0) begin
            if (sys_rst_n && saw_ready && saw_load_start &&
                (beacon_block_ack_count >= full_gate_prefix_block_ack_target) &&
                (beacon_max_block_ack_arg >= (full_gate_prefix_block_ack_target - 1)) &&
                (beacon_block_nack_count == 0) && !saw_bad) begin
                $display("[AX7203_DDR3_LOADER] PASS prefix=1 ready=%0b load_start=%0b block_ack=%0d block_nack=%0d max_block_ack=%0d target=%0d bad=%0b uart_bytes=%0d pass_bytes=%0d beacon_good=%0d beacon_bad=%0d tube=%02h led=%b",
                         saw_ready, saw_load_start, beacon_block_ack_count, beacon_block_nack_count, beacon_max_block_ack_arg, full_gate_prefix_block_ack_target, saw_bad,
                         uart_byte_count, passthrough_byte_count, beacon_good_frames, beacon_bad_frames, dut.tube_status, led);
                $finish;
            end
        end else if (sys_rst_n && saw_ready && saw_load_start && saw_read_ok && saw_load_ok && saw_jump && saw_summary &&
                     ((summary_mask & (LOADER_SUM_READY | LOADER_SUM_LOAD_START | LOADER_SUM_READ_OK | LOADER_SUM_LOAD_OK | LOADER_SUM_JUMP)) ==
                      (LOADER_SUM_READY | LOADER_SUM_LOAD_START | LOADER_SUM_READ_OK | LOADER_SUM_LOAD_OK | LOADER_SUM_JUMP)) &&
                     ((summary_mask & LOADER_SUM_ANY_BAD) == 0) && !saw_bad) begin
            if ((expect_exec_pass != 0) && !saw_exec_pass)
                ;
            else begin
                $display("[AX7203_DDR3_LOADER] PASS prefix=0 ready=%0b load_start=%0b read_ok=%0b load_ok=%0b jump=%0b summary=%0b mask=%02h bad=%0b exec_pass=%0b uart_bytes=%0d pass_bytes=%0d block_ack=%0d block_nack=%0d beacon_good=%0d beacon_bad=%0d tube=%02h led=%b",
                         saw_ready, saw_load_start, saw_read_ok, saw_load_ok, saw_jump, saw_summary, summary_mask, saw_bad, saw_exec_pass,
                         uart_byte_count, passthrough_byte_count, block_ack_count, block_nack_count, beacon_good_frames, beacon_bad_frames,
                         dut.tube_status, led);
                $finish;
            end
        end
    end
endmodule
