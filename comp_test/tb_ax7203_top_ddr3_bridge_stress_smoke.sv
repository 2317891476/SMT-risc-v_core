`timescale 1ns/1ps

module tb_ax7203_top_ddr3_bridge_stress_smoke;
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
    localparam integer TB_TIMEOUT_NS = 30_000_000;
`endif
    localparam [95:0] READY_TOKEN = 96'h425249444745205245414459;      // BRIDGE READY
    localparam [71:0] OK_TOKEN    = 72'h425249444745204F4B;            // BRIDGE OK
    localparam [111:0] BAD_TOKEN  = 112'h4252494447452042414420424C4B3D; // BRIDGE BAD BLK=

    integer uart_byte_count;
    integer uart_trace_count;
    integer ok_token_hits;
    reg saw_ready;
    reg saw_bad;
    reg [127:0] shift128;

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
        ok_token_hits = 0;
        saw_ready = 1'b0;
        saw_bad = 1'b0;
        shift128 = 128'd0;
        #100;
        sys_rst_n = 1'b1;
    end

    always @(posedge core_uart_tx_start) begin
        uart_byte_count <= uart_byte_count + 1;
        shift128 <= {shift128[119:0], core_uart_tx_byte};

        if (uart_trace_count < 160) begin
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

        if ({shift128[87:0], core_uart_tx_byte} == READY_TOKEN) begin
            saw_ready <= 1'b1;
            $display("\n[AX7203_DDR3_BRIDGE] saw READY at byte %0d", uart_byte_count + 1);
        end
        if ({shift128[63:0], core_uart_tx_byte} == OK_TOKEN) begin
            ok_token_hits <= ok_token_hits + 1;
            $display("\n[AX7203_DDR3_BRIDGE] saw OK token #%0d at byte %0d", ok_token_hits + 1, uart_byte_count + 1);
        end
        if ({shift128[103:0], core_uart_tx_byte} == BAD_TOKEN) begin
            saw_bad <= 1'b1;
            $display("\n[AX7203_DDR3_BRIDGE] saw BAD token at byte %0d", uart_byte_count + 1);
        end
    end

    initial begin : progress_trace
        forever begin
            #1_000_000;
            $display("[AX7203_DDR3_BRIDGE] PROGRESS t=%0t ready=%0b retire=%0b calib=%0b tube=%02h uart_bytes=%0d ok_hits=%0d bad=%0b core_acc=%0d ui_cons=%0d ar=%0d r=%0d aw=%0d w=%0d b=%0d resp=%0d flags timeout=%0b stuck=%0b dup=%0b led=%b",
                     $time,
                     dut.core_ready,
                     dut.core_retire_seen,
                     dut.mig_init_calib_complete,
                     dut.tube_status,
                     uart_byte_count,
                     ok_token_hits,
                     saw_bad,
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
        $display("[AX7203_DDR3_BRIDGE] TIMEOUT ready=%0b retire=%0b calib=%0b tube=%02h uart_bytes=%0d ok_hits=%0d bad=%0b core_acc=%0d ui_cons=%0d ar=%0d r=%0d aw=%0d w=%0d b=%0d resp=%0d flags timeout=%0b stuck=%0b dup=%0b last_req=%08h/%0b last_resp=%08h led=%b",
                 saw_ready,
                 dut.core_retire_seen,
                 dut.mig_init_calib_complete,
                 dut.tube_status,
                 uart_byte_count,
                 ok_token_hits,
                 saw_bad,
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
        if (sys_rst_n && saw_bad) begin
            $display("[AX7203_DDR3_BRIDGE] FAIL saw_bad=1 tube=%02h", dut.tube_status);
            $fatal(1);
        end
        if (sys_rst_n &&
            dut.core_ready &&
            dut.core_retire_seen &&
            dut.mig_init_calib_complete &&
            (dut.tube_status == 8'h04) &&
            (ok_token_hits >= 1) &&
            !dut.u_ddr3_mem_port.debug_req_pending_timeout_flag_r &&
            !dut.u_ddr3_mem_port.debug_ui_state_stuck_flag_r &&
            !dut.u_ddr3_mem_port.debug_duplicate_resp_flag_r) begin
            $display("[AX7203_DDR3_BRIDGE] PASS ready=%0b retire=%0b calib=%0b tube=%02h uart_bytes=%0d ok_hits=%0d core_acc=%0d ui_cons=%0d ar=%0d r=%0d aw=%0d w=%0d b=%0d resp=%0d led=%b",
                     saw_ready,
                     dut.core_retire_seen,
                     dut.mig_init_calib_complete,
                     dut.tube_status,
                     uart_byte_count,
                     ok_token_hits,
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
