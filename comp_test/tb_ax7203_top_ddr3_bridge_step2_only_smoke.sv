`timescale 1ns/1ps

module tb_ax7203_top_ddr3_bridge_step2_only_smoke;
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
    localparam integer TB_TIMEOUT_NS = 2_000_000;
`endif

    localparam [7:0] SOF_BYTE     = 8'hA5;
    localparam [7:0] EVT_READY    = 8'h01;
    localparam [7:0] EVT_C1_OK    = 8'h11;
    localparam [7:0] EVT_C2_OK    = 8'h12;
    localparam [7:0] EVT_C3_START = 8'h31;
    localparam [7:0] EVT_C3_AFTER = 8'h32;
    localparam [7:0] EVT_C3_OK    = 8'h33;
    localparam [7:0] EVT_C4_START = 8'h41;
    localparam [7:0] EVT_C4_AFTER = 8'h42;
    localparam [7:0] EVT_C4_OK    = 8'h43;
    localparam [7:0] EVT_C5_START = 8'h51;
    localparam [7:0] EVT_C5_AFTER = 8'h52;
    localparam [7:0] EVT_C5_OK    = 8'h53;
    localparam [7:0] EVT_BAD      = 8'hE0;
    localparam [7:0] EVT_CAL_FAIL = 8'hE1;
    localparam [7:0] EVT_TRAP     = 8'hEF;
    localparam [7:0] EVT_SUMMARY  = 8'hF0;

    integer uart_byte_count;
    integer good_frame_count;
    integer bad_frame_count;
    integer duplicate_frame_count;
    reg saw_ready;
    reg saw_case1_ok;
    reg saw_case2_ok;
    reg saw_case3_start;
    reg saw_case3_after_write;
    reg saw_case3_ok;
    reg saw_case4_start;
    reg saw_case4_after_write;
    reg saw_case4_ok;
    reg saw_case5_start;
    reg saw_case5_after_write;
    reg saw_case5_ok;
    reg saw_summary;
    reg saw_bad;
    reg saw_trap;
    reg saw_cal_fail;
    reg [7:0] summary_mask;
    reg [3:0] bad_case;
    reg [3:0] bad_phase;
    reg [2:0] parser_state;
    reg [7:0] frame_seq;
    reg [7:0] frame_type;
    reg [7:0] frame_arg;
    reg [255:0] seen_seq_bitmap;

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
        uart_byte_count = 0;
        good_frame_count = 0;
        bad_frame_count = 0;
        duplicate_frame_count = 0;
        saw_ready = 1'b0;
        saw_case1_ok = 1'b0;
        saw_case2_ok = 1'b0;
        saw_case3_start = 1'b0;
        saw_case3_after_write = 1'b0;
        saw_case3_ok = 1'b0;
        saw_case4_start = 1'b0;
        saw_case4_after_write = 1'b0;
        saw_case4_ok = 1'b0;
        saw_case5_start = 1'b0;
        saw_case5_after_write = 1'b0;
        saw_case5_ok = 1'b0;
        saw_summary = 1'b0;
        saw_bad = 1'b0;
        saw_trap = 1'b0;
        saw_cal_fail = 1'b0;
        summary_mask = 8'd0;
        bad_case = 4'd0;
        bad_phase = 4'd0;
        parser_state = 3'd0;
        frame_seq = 8'd0;
        frame_type = 8'd0;
        frame_arg = 8'd0;
        seen_seq_bitmap = 256'd0;
        #100;
        sys_rst_n = 1'b1;
    end

    task automatic accept_frame;
        input [7:0] seq;
        input [7:0] kind;
        input [7:0] arg;
        begin
            if (seen_seq_bitmap[seq]) begin
                duplicate_frame_count <= duplicate_frame_count + 1;
            end else begin
                seen_seq_bitmap[seq] <= 1'b1;
                good_frame_count <= good_frame_count + 1;
                case (kind)
                    EVT_READY: begin
                        saw_ready <= 1'b1;
                        $display("[AX7203_DDR3_S2] EVT READY seq=%0d", seq);
                    end
                    EVT_C1_OK: begin
                        saw_case1_ok <= 1'b1;
                        $display("[AX7203_DDR3_S2] EVT C1_OK seq=%0d", seq);
                    end
                    EVT_C2_OK: begin
                        saw_case2_ok <= 1'b1;
                        $display("[AX7203_DDR3_S2] EVT C2_OK seq=%0d", seq);
                    end
                    EVT_C3_START: begin
                        saw_case3_start <= 1'b1;
                        $display("[AX7203_DDR3_S2] EVT C3_START seq=%0d", seq);
                    end
                    EVT_C3_AFTER: begin
                        saw_case3_after_write <= 1'b1;
                        $display("[AX7203_DDR3_S2] EVT C3_AFTER seq=%0d", seq);
                    end
                    EVT_C3_OK: begin
                        saw_case3_ok <= 1'b1;
                        $display("[AX7203_DDR3_S2] EVT C3_OK seq=%0d", seq);
                    end
                    EVT_C4_START: begin
                        saw_case4_start <= 1'b1;
                        $display("[AX7203_DDR3_S2] EVT C4_START seq=%0d", seq);
                    end
                    EVT_C4_AFTER: begin
                        saw_case4_after_write <= 1'b1;
                        $display("[AX7203_DDR3_S2] EVT C4_AFTER seq=%0d", seq);
                    end
                    EVT_C4_OK: begin
                        saw_case4_ok <= 1'b1;
                        $display("[AX7203_DDR3_S2] EVT C4_OK seq=%0d", seq);
                    end
                    EVT_C5_START: begin
                        saw_case5_start <= 1'b1;
                        $display("[AX7203_DDR3_S2] EVT C5_START seq=%0d", seq);
                    end
                    EVT_C5_AFTER: begin
                        saw_case5_after_write <= 1'b1;
                        $display("[AX7203_DDR3_S2] EVT C5_AFTER seq=%0d", seq);
                    end
                    EVT_C5_OK: begin
                        saw_case5_ok <= 1'b1;
                        $display("[AX7203_DDR3_S2] EVT C5_OK seq=%0d", seq);
                    end
                    EVT_BAD: begin
                        saw_bad <= 1'b1;
                        bad_case <= arg[3:0];
                        bad_phase <= arg[7:4];
                        $display("[AX7203_DDR3_S2] EVT BAD seq=%0d case=%0d phase=%0d", seq, arg[3:0], arg[7:4]);
                    end
                    EVT_CAL_FAIL: begin
                        saw_cal_fail <= 1'b1;
                        $display("[AX7203_DDR3_S2] EVT CAL_FAIL seq=%0d", seq);
                    end
                    EVT_TRAP: begin
                        saw_trap <= 1'b1;
                        $display("[AX7203_DDR3_S2] EVT TRAP seq=%0d", seq);
                    end
                    EVT_SUMMARY: begin
                        saw_summary <= 1'b1;
                        summary_mask <= arg;
                        $display("[AX7203_DDR3_S2] EVT SUMMARY seq=%0d mask=%02x", seq, arg);
                    end
                    default: begin
                        $display("[AX7203_DDR3_S2] EVT UNKNOWN seq=%0d type=%02x arg=%02x", seq, kind, arg);
                    end
                endcase
            end
        end
    endtask

    always @(posedge core_uart_tx_start) begin
        uart_byte_count <= uart_byte_count + 1;
        case (parser_state)
            3'd0: begin
                if (core_uart_tx_byte == SOF_BYTE)
                    parser_state <= 3'd1;
            end
            3'd1: begin
                frame_seq <= core_uart_tx_byte;
                parser_state <= 3'd2;
            end
            3'd2: begin
                frame_type <= core_uart_tx_byte;
                parser_state <= 3'd3;
            end
            3'd3: begin
                frame_arg <= core_uart_tx_byte;
                parser_state <= 3'd4;
            end
            3'd4: begin
                if (core_uart_tx_byte == (SOF_BYTE ^ frame_seq ^ frame_type ^ frame_arg))
                    accept_frame(frame_seq, frame_type, frame_arg);
                else
                    bad_frame_count <= bad_frame_count + 1;
                parser_state <= 3'd0;
            end
            default: begin
                parser_state <= 3'd0;
            end
        endcase
    end

    initial begin : progress_trace
        forever begin
            #100_000;
            $display("[AX7203_DDR3_S2] PROGRESS t=%0t ready=%0b retire=%0b calib=%0b tube=%02h bytes=%0d good=%0d bad=%0d dup=%0d c1=%0b c2=%0b c3s=%0b c3a=%0b c3=%0b c4s=%0b c4a=%0b c4=%0b c5s=%0b c5a=%0b c5=%0b summary=%0b mask=%02h bad_evt=%0b trap=%0b cal_fail=%0b core_acc=%0d ui_cons=%0d ar=%0d r=%0d aw=%0d w=%0d b=%0d resp=%0d flags timeout=%0b stuck=%0b dup_flag=%0b led=%b",
                     $time,
                     saw_ready,
                     dut.core_retire_seen,
                     dut.mig_init_calib_complete,
                     dut.tube_status,
                     uart_byte_count,
                     good_frame_count,
                     bad_frame_count,
                     duplicate_frame_count,
                     saw_case1_ok,
                     saw_case2_ok,
                     saw_case3_start,
                     saw_case3_after_write,
                     saw_case3_ok,
                     saw_case4_start,
                     saw_case4_after_write,
                     saw_case4_ok,
                     saw_case5_start,
                     saw_case5_after_write,
                     saw_case5_ok,
                     saw_summary,
                     summary_mask,
                     saw_bad,
                     saw_trap,
                     saw_cal_fail,
                     dut.u_ddr3_mem_port.debug_core_req_accept_count_r,
                     dut.u_ddr3_mem_port.debug_ui_req_consume_count_r,
                     dut.u_ddr3_mem_port.debug_axi_ar_count_r,
                     dut.u_ddr3_mem_port.debug_axi_r_count_r,
                     dut.u_ddr3_mem_port.debug_axi_aw_count_r,
                     dut.u_ddr3_mem_port.debug_axi_w_count_r,
                     dut.u_ddr3_mem_port.debug_axi_b_count_r,
                     dut.u_ddr3_mem_port.debug_resp_toggle_count_r,
                     dut.u_ddr3_mem_port.debug_req_pending_timeout_flag_r,
                     dut.u_ddr3_mem_port.debug_ui_state_stuck_flag_r,
                     dut.u_ddr3_mem_port.debug_duplicate_resp_flag_r,
                     led);
        end
    end

    initial begin : timeout_guard
        #TB_TIMEOUT_NS;
        $display("[AX7203_DDR3_S2] TIMEOUT ready=%0b retire=%0b calib=%0b tube=%02h bytes=%0d good=%0d bad=%0d dup=%0d c1=%0b c2=%0b c3s=%0b c3a=%0b c3=%0b c4s=%0b c4a=%0b c4=%0b c5s=%0b c5a=%0b c5=%0b summary=%0b mask=%02h bad_evt=%0b case=%0d phase=%0d trap=%0b cal_fail=%0b last_req=%08h/%0b last_resp=%08h led=%b",
                 saw_ready,
                 dut.core_retire_seen,
                 dut.mig_init_calib_complete,
                 dut.tube_status,
                 uart_byte_count,
                 good_frame_count,
                 bad_frame_count,
                 duplicate_frame_count,
                 saw_case1_ok,
                 saw_case2_ok,
                 saw_case3_start,
                 saw_case3_after_write,
                 saw_case3_ok,
                 saw_case4_start,
                 saw_case4_after_write,
                 saw_case4_ok,
                 saw_case5_start,
                 saw_case5_after_write,
                 saw_case5_ok,
                 saw_summary,
                 summary_mask,
                 saw_bad,
                 bad_case,
                 bad_phase,
                 saw_trap,
                 saw_cal_fail,
                 dut.u_ddr3_mem_port.debug_last_req_addr_r,
                 dut.u_ddr3_mem_port.debug_last_req_write_r,
                 dut.u_ddr3_mem_port.debug_last_resp_data_r,
                 led);
        $fatal(1);
    end

    always @(posedge sys_clk_p) begin
        if (sys_rst_n && ((dut.tube_status == 8'hE0) || (dut.tube_status == 8'hE1) || (dut.tube_status == 8'hE2) || (dut.tube_status == 8'hE3) || (dut.tube_status == 8'hE4) || (dut.tube_status == 8'hE5) || (dut.tube_status == 8'hEF))) begin
            $display("[AX7203_DDR3_S2] FAIL tube failure state=%02h", dut.tube_status);
            $fatal(1);
        end

        if (sys_rst_n && (saw_bad || saw_trap || saw_cal_fail)) begin
            $display("[AX7203_DDR3_S2] FAIL saw_bad=%0b case=%0d phase=%0d saw_trap=%0b saw_cal_fail=%0b tube=%02h",
                     saw_bad, bad_case, bad_phase, saw_trap, saw_cal_fail, dut.tube_status);
            $fatal(1);
        end

        if (sys_rst_n &&
            dut.core_ready &&
            dut.core_retire_seen &&
            dut.mig_init_calib_complete &&
            (dut.tube_status == 8'h04) &&
            saw_ready &&
            saw_case1_ok &&
            saw_case2_ok &&
            saw_case3_start &&
            saw_case3_after_write &&
            saw_case3_ok &&
            saw_case4_start &&
            saw_case4_after_write &&
            saw_case4_ok &&
            saw_case5_start &&
            saw_case5_after_write &&
            saw_case5_ok &&
            saw_summary &&
            (summary_mask[4:0] == 5'b1_1111) &&
            !summary_mask[7] &&
            !dut.u_ddr3_mem_port.debug_req_pending_timeout_flag_r &&
            !dut.u_ddr3_mem_port.debug_ui_state_stuck_flag_r &&
            !dut.u_ddr3_mem_port.debug_duplicate_resp_flag_r) begin
            $display("[AX7203_DDR3_S2] PASS ready=%0b retire=%0b calib=%0b tube=%02h bytes=%0d good=%0d bad=%0d dup=%0d mask=%02h c1=%0b c2=%0b c3s=%0b c3a=%0b c3=%0b c4s=%0b c4a=%0b c4=%0b c5s=%0b c5a=%0b c5=%0b core_acc=%0d ui_cons=%0d ar=%0d r=%0d aw=%0d w=%0d b=%0d resp=%0d led=%b",
                     saw_ready,
                     dut.core_retire_seen,
                     dut.mig_init_calib_complete,
                     dut.tube_status,
                     uart_byte_count,
                     good_frame_count,
                     bad_frame_count,
                     duplicate_frame_count,
                     summary_mask,
                     saw_case1_ok,
                     saw_case2_ok,
                     saw_case3_start,
                     saw_case3_after_write,
                     saw_case3_ok,
                     saw_case4_start,
                     saw_case4_after_write,
                     saw_case4_ok,
                     saw_case5_start,
                     saw_case5_after_write,
                     saw_case5_ok,
                     dut.u_ddr3_mem_port.debug_core_req_accept_count_r,
                     dut.u_ddr3_mem_port.debug_ui_req_consume_count_r,
                     dut.u_ddr3_mem_port.debug_axi_ar_count_r,
                     dut.u_ddr3_mem_port.debug_axi_r_count_r,
                     dut.u_ddr3_mem_port.debug_axi_aw_count_r,
                     dut.u_ddr3_mem_port.debug_axi_w_count_r,
                     dut.u_ddr3_mem_port.debug_axi_b_count_r,
                     dut.u_ddr3_mem_port.debug_resp_toggle_count_r,
                     led);
            $finish;
        end
    end
endmodule
