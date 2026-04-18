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

    localparam [8*8-1:0]  READY_TOKEN       = "S2 READY";
    localparam [8*9-1:0]  CASE1_TOKEN       = "S2 OK C=1";
    localparam [8*9-1:0]  CASE2_TOKEN       = "S2 OK C=2";
    localparam [8*9-1:0]  CASE3_TOKEN       = "S2 OK C=3";
    localparam [8*9-1:0]  CASE4_TOKEN       = "S2 OK C=4";
    localparam [8*9-1:0]  CASE5_TOKEN       = "S2 OK C=5";
    localparam [8*12-1:0] CASE3_START_TOKEN = "S2 START C=3";
    localparam [8*12-1:0] CASE4_START_TOKEN = "S2 START C=4";
    localparam [8*12-1:0] CASE5_START_TOKEN = "S2 START C=5";
    localparam [8*18-1:0] CASE3_AFTER_TOKEN = "S2 AFTER WRITE C=3";
    localparam [8*18-1:0] CASE4_AFTER_TOKEN = "S2 AFTER WRITE C=4";
    localparam [8*18-1:0] CASE5_AFTER_TOKEN = "S2 AFTER WRITE C=5";
    localparam [8*6-1:0]  BAD_TOKEN         = "S2 BAD";
    localparam [8*7-1:0]  TRAP_TOKEN        = "S2 TRAP";
    localparam [8*9-1:0]  ALL_OK_TOKEN      = "S2 ALL OK";

    integer uart_byte_count;
    integer uart_trace_count;
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
    reg saw_all_ok;
    reg saw_bad;
    reg saw_trap;
    reg [159:0] shift160;

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
        uart_trace_count = 0;
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
        saw_all_ok = 1'b0;
        saw_bad = 1'b0;
        saw_trap = 1'b0;
        shift160 = 160'd0;
        #100;
        sys_rst_n = 1'b1;
    end

    always @(posedge core_uart_tx_start) begin
        uart_byte_count <= uart_byte_count + 1;
        shift160 <= {shift160[151:0], core_uart_tx_byte};

        if (uart_trace_count < 256) begin
            if (core_uart_tx_byte >= 8'h20 && core_uart_tx_byte <= 8'h7e)
                $write("%c", core_uart_tx_byte);
            else if (core_uart_tx_byte == 8'h0d)
                $write("<CR>");
            else if (core_uart_tx_byte == 8'h0a)
                $write("<LF>\n");
            else
                $write("<%02x>", core_uart_tx_byte);
            uart_trace_count <= uart_trace_count + 1;
        end

        if ({shift160[55:0], core_uart_tx_byte} == READY_TOKEN) begin
            saw_ready <= 1'b1;
            $display("\n[AX7203_DDR3_S2] saw READY at byte %0d", uart_byte_count + 1);
        end
        if ({shift160[63:0], core_uart_tx_byte} == CASE1_TOKEN) begin
            saw_case1_ok <= 1'b1;
            $display("\n[AX7203_DDR3_S2] saw CASE1 OK at byte %0d", uart_byte_count + 1);
        end
        if ({shift160[63:0], core_uart_tx_byte} == CASE2_TOKEN) begin
            saw_case2_ok <= 1'b1;
            $display("\n[AX7203_DDR3_S2] saw CASE2 OK at byte %0d", uart_byte_count + 1);
        end
        if ({shift160[87:0], core_uart_tx_byte} == CASE3_START_TOKEN) begin
            saw_case3_start <= 1'b1;
            $display("\n[AX7203_DDR3_S2] saw CASE3 START at byte %0d", uart_byte_count + 1);
        end
        if ({shift160[135:0], core_uart_tx_byte} == CASE3_AFTER_TOKEN) begin
            saw_case3_after_write <= 1'b1;
            $display("\n[AX7203_DDR3_S2] saw CASE3 AFTER WRITE at byte %0d", uart_byte_count + 1);
        end
        if ({shift160[63:0], core_uart_tx_byte} == CASE3_TOKEN) begin
            saw_case3_ok <= 1'b1;
            $display("\n[AX7203_DDR3_S2] saw CASE3 OK at byte %0d", uart_byte_count + 1);
        end
        if ({shift160[87:0], core_uart_tx_byte} == CASE4_START_TOKEN) begin
            saw_case4_start <= 1'b1;
            $display("\n[AX7203_DDR3_S2] saw CASE4 START at byte %0d", uart_byte_count + 1);
        end
        if ({shift160[135:0], core_uart_tx_byte} == CASE4_AFTER_TOKEN) begin
            saw_case4_after_write <= 1'b1;
            $display("\n[AX7203_DDR3_S2] saw CASE4 AFTER WRITE at byte %0d", uart_byte_count + 1);
        end
        if ({shift160[63:0], core_uart_tx_byte} == CASE4_TOKEN) begin
            saw_case4_ok <= 1'b1;
            $display("\n[AX7203_DDR3_S2] saw CASE4 OK at byte %0d", uart_byte_count + 1);
        end
        if ({shift160[87:0], core_uart_tx_byte} == CASE5_START_TOKEN) begin
            saw_case5_start <= 1'b1;
            $display("\n[AX7203_DDR3_S2] saw CASE5 START at byte %0d", uart_byte_count + 1);
        end
        if ({shift160[135:0], core_uart_tx_byte} == CASE5_AFTER_TOKEN) begin
            saw_case5_after_write <= 1'b1;
            $display("\n[AX7203_DDR3_S2] saw CASE5 AFTER WRITE at byte %0d", uart_byte_count + 1);
        end
        if ({shift160[63:0], core_uart_tx_byte} == CASE5_TOKEN) begin
            saw_case5_ok <= 1'b1;
            $display("\n[AX7203_DDR3_S2] saw CASE5 OK at byte %0d", uart_byte_count + 1);
        end
        if ({shift160[39:0], core_uart_tx_byte} == BAD_TOKEN) begin
            saw_bad <= 1'b1;
            $display("\n[AX7203_DDR3_S2] saw BAD token at byte %0d", uart_byte_count + 1);
        end
        if ({shift160[47:0], core_uart_tx_byte} == TRAP_TOKEN) begin
            saw_trap <= 1'b1;
            $display("\n[AX7203_DDR3_S2] saw TRAP token at byte %0d", uart_byte_count + 1);
        end
        if ({shift160[63:0], core_uart_tx_byte} == ALL_OK_TOKEN) begin
            saw_all_ok <= 1'b1;
            $display("\n[AX7203_DDR3_S2] saw ALL OK at byte %0d", uart_byte_count + 1);
        end
    end

    initial begin : progress_trace
        forever begin
            #100_000;
            $display("[AX7203_DDR3_S2] PROGRESS t=%0t ready=%0b retire=%0b calib=%0b tube=%02h uart_bytes=%0d c1=%0b c2=%0b c3s=%0b c3a=%0b c3=%0b c4s=%0b c4a=%0b c4=%0b c5s=%0b c5a=%0b c5=%0b all_ok=%0b bad=%0b trap=%0b core_acc=%0d ui_cons=%0d ar=%0d r=%0d aw=%0d w=%0d b=%0d resp=%0d flags timeout=%0b stuck=%0b dup=%0b led=%b",
                     $time,
                     dut.core_ready,
                     dut.core_retire_seen,
                     dut.mig_init_calib_complete,
                     dut.tube_status,
                     uart_byte_count,
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
                     saw_all_ok,
                     saw_bad,
                     saw_trap,
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
        $display("[AX7203_DDR3_S2] TIMEOUT ready=%0b retire=%0b calib=%0b tube=%02h uart_bytes=%0d c1=%0b c2=%0b c3s=%0b c3a=%0b c3=%0b c4s=%0b c4a=%0b c4=%0b c5s=%0b c5a=%0b c5=%0b all_ok=%0b bad=%0b trap=%0b core_acc=%0d ui_cons=%0d ar=%0d r=%0d aw=%0d w=%0d b=%0d resp=%0d flags timeout=%0b stuck=%0b dup=%0b last_req=%08h/%0b last_resp=%08h led=%b",
                 saw_ready,
                 dut.core_retire_seen,
                 dut.mig_init_calib_complete,
                 dut.tube_status,
                 uart_byte_count,
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
                 saw_all_ok,
                 saw_bad,
                 saw_trap,
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
                 dut.u_ddr3_mem_port.debug_last_req_addr_r,
                 dut.u_ddr3_mem_port.debug_last_req_write_r,
                 dut.u_ddr3_mem_port.debug_last_resp_data_r,
                 led);
        $fatal(1);
    end

    always @(posedge sys_clk_p) begin
        if (sys_rst_n) begin
            if ((dut.tube_status == 8'h62) || (dut.tube_status == 8'h63) || (dut.tube_status == 8'h64) || (dut.tube_status == 8'h65) || (dut.tube_status == 8'h04))
                saw_case1_ok <= 1'b1;
            if ((dut.tube_status == 8'h63) || (dut.tube_status == 8'h64) || (dut.tube_status == 8'h65) || (dut.tube_status == 8'h04))
                saw_case2_ok <= 1'b1;
        end

        if (sys_rst_n && ((dut.tube_status == 8'hE1) || (dut.tube_status == 8'hE2) || (dut.tube_status == 8'hE3) || (dut.tube_status == 8'hE4) || (dut.tube_status == 8'hE5))) begin
            $display("[AX7203_DDR3_S2] FAIL tube failure state=%02h", dut.tube_status);
            $fatal(1);
        end

        if (sys_rst_n && (saw_bad || saw_trap)) begin
            $display("[AX7203_DDR3_S2] FAIL saw_bad=%0b saw_trap=%0b tube=%02h", saw_bad, saw_trap, dut.tube_status);
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
            saw_all_ok &&
            !dut.u_ddr3_mem_port.debug_req_pending_timeout_flag_r &&
            !dut.u_ddr3_mem_port.debug_ui_state_stuck_flag_r &&
            !dut.u_ddr3_mem_port.debug_duplicate_resp_flag_r) begin
            $display("[AX7203_DDR3_S2] PASS ready=%0b retire=%0b calib=%0b tube=%02h uart_bytes=%0d c1=%0b c2=%0b c3s=%0b c3a=%0b c3=%0b c4s=%0b c4a=%0b c4=%0b c5s=%0b c5a=%0b c5=%0b all_ok=%0b core_acc=%0d ui_cons=%0d ar=%0d r=%0d aw=%0d w=%0d b=%0d resp=%0d led=%b",
                     saw_ready,
                     dut.core_retire_seen,
                     dut.mig_init_calib_complete,
                     dut.tube_status,
                     uart_byte_count,
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
                     saw_all_ok,
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
