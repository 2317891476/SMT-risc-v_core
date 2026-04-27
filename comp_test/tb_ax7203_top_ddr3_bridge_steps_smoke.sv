`timescale 1ns/1ps

module tb_ax7203_top_ddr3_bridge_steps_smoke;
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
    localparam integer TB_TIMEOUT_NS = 35_000_000;
`endif

    localparam [8*11-1:0] READY_TOKEN  = "BSTEP READY";
    localparam [8*12-1:0] STEP1_TOKEN  = "BSTEP OK S=1";
    localparam [8*12-1:0] STEP2_TOKEN  = "BSTEP OK S=2";
    localparam [8*12-1:0] STEP3_TOKEN  = "BSTEP OK S=3";
    localparam [8*9-1:0]  BAD_TOKEN    = "BSTEP BAD";
    localparam [8*12-1:0] ALL_OK_TOKEN = "BSTEP ALL OK";

    integer uart_byte_count;
    integer uart_trace_count;
    reg saw_ready;
    reg saw_step1_ok;
    reg saw_step2_ok;
    reg saw_step3_ok;
    reg saw_all_ok;
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
        saw_ready = 1'b0;
        saw_step1_ok = 1'b0;
        saw_step2_ok = 1'b0;
        saw_step3_ok = 1'b0;
        saw_all_ok = 1'b0;
        saw_bad = 1'b0;
        shift128 = 128'd0;
        #100;
        sys_rst_n = 1'b1;
    end

    always @(posedge core_uart_tx_start) begin
        uart_byte_count <= uart_byte_count + 1;
        shift128 <= {shift128[119:0], core_uart_tx_byte};

        if (uart_trace_count < 220) begin
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

        if ({shift128[79:0], core_uart_tx_byte} == READY_TOKEN) begin
            saw_ready <= 1'b1;
            $display("\n[AX7203_DDR3_BSTEPS] saw READY at byte %0d", uart_byte_count + 1);
        end
        if ({shift128[87:0], core_uart_tx_byte} == STEP1_TOKEN) begin
            saw_step1_ok <= 1'b1;
            $display("\n[AX7203_DDR3_BSTEPS] saw STEP1 OK at byte %0d", uart_byte_count + 1);
        end
        if ({shift128[87:0], core_uart_tx_byte} == STEP2_TOKEN) begin
            saw_step2_ok <= 1'b1;
            $display("\n[AX7203_DDR3_BSTEPS] saw STEP2 OK at byte %0d", uart_byte_count + 1);
        end
        if ({shift128[87:0], core_uart_tx_byte} == STEP3_TOKEN) begin
            saw_step3_ok <= 1'b1;
            $display("\n[AX7203_DDR3_BSTEPS] saw STEP3 OK at byte %0d", uart_byte_count + 1);
        end
        if ({shift128[63:0], core_uart_tx_byte} == BAD_TOKEN) begin
            saw_bad <= 1'b1;
            $display("\n[AX7203_DDR3_BSTEPS] saw BAD token at byte %0d", uart_byte_count + 1);
        end
        if ({shift128[87:0], core_uart_tx_byte} == ALL_OK_TOKEN) begin
            saw_all_ok <= 1'b1;
            $display("\n[AX7203_DDR3_BSTEPS] saw ALL OK at byte %0d", uart_byte_count + 1);
        end
    end

    initial begin : progress_trace
        forever begin
            #100_000;
            $display("[AX7203_DDR3_BSTEPS] PROGRESS t=%0t ready=%0b retire=%0b calib=%0b tube=%02h uart_bytes=%0d step1=%0b step2=%0b step3=%0b all_ok=%0b bad=%0b core_acc=%0d ui_cons=%0d ar=%0d r=%0d aw=%0d w=%0d b=%0d resp=%0d flags timeout=%0b stuck=%0b dup=%0b led=%b",
                     $time,
                     dut.core_ready,
                     dut.core_retire_seen,
                     dut.mig_init_calib_complete,
                     dut.tube_status,
                     uart_byte_count,
                     saw_step1_ok,
                     saw_step2_ok,
                     saw_step3_ok,
                     saw_all_ok,
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
        $display("[AX7203_DDR3_BSTEPS] TIMEOUT ready=%0b retire=%0b calib=%0b tube=%02h uart_bytes=%0d step1=%0b step2=%0b step3=%0b all_ok=%0b bad=%0b core_acc=%0d ui_cons=%0d ar=%0d r=%0d aw=%0d w=%0d b=%0d resp=%0d flags timeout=%0b stuck=%0b dup=%0b last_req=%08h/%0b last_resp=%08h led=%b",
                 saw_ready,
                 dut.core_retire_seen,
                 dut.mig_init_calib_complete,
                 dut.tube_status,
                 uart_byte_count,
                 saw_step1_ok,
                 saw_step2_ok,
                 saw_step3_ok,
                 saw_all_ok,
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
        if (sys_rst_n) begin
            if ((dut.tube_status == 8'h42) || (dut.tube_status == 8'h43) || (dut.tube_status == 8'h04))
                saw_step1_ok <= 1'b1;
            if ((dut.tube_status == 8'h43) || (dut.tube_status == 8'h04))
                saw_step2_ok <= 1'b1;
        end
        if (sys_rst_n && saw_bad) begin
            $display("[AX7203_DDR3_BSTEPS] FAIL saw_bad=1 tube=%02h", dut.tube_status);
            $fatal(1);
        end
        if (sys_rst_n &&
            dut.core_ready &&
            dut.core_retire_seen &&
            dut.mig_init_calib_complete &&
            (dut.tube_status == 8'h04) &&
            saw_ready &&
            saw_step1_ok &&
            saw_step2_ok &&
            saw_step3_ok &&
            saw_all_ok &&
            !dut.u_ddr3_mem_port.debug_req_pending_timeout_flag_r &&
            !dut.u_ddr3_mem_port.debug_ui_state_stuck_flag_r &&
            !dut.u_ddr3_mem_port.debug_duplicate_resp_flag_r) begin
            $display("[AX7203_DDR3_BSTEPS] PASS ready=%0b retire=%0b calib=%0b tube=%02h uart_bytes=%0d step1=%0b step2=%0b step3=%0b all_ok=%0b core_acc=%0d ui_cons=%0d ar=%0d r=%0d aw=%0d w=%0d b=%0d resp=%0d led=%b",
                     saw_ready,
                     dut.core_retire_seen,
                     dut.mig_init_calib_complete,
                     dut.tube_status,
                     uart_byte_count,
                     saw_step1_ok,
                     saw_step2_ok,
                     saw_step3_ok,
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
