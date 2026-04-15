`timescale 1ns/1ps

module tb_ax7203_top_mainline_ddr3_smoke;
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

    integer uart_byte_count;
    integer uart_trace_count;
    integer count_u, count_a, count_r, count_t, count_d, count_i, count_g, count_p, count_s;
    reg saw_space;
    reg saw_cr;
    reg saw_lf;
    reg saw_cal_token;
    reg saw_ddr3_pass_token;
    reg saw_ddr3_word;
    reg saw_uart_banner_chars;
    reg [39:0] cal_shift;
    reg [71:0] ddr3_pass_shift;
    wire core_uart_tx_start = dut.core_uart_byte_valid_dbg;
    wire [7:0] core_uart_tx_byte = dut.core_uart_byte_dbg;

`ifdef TB_SHORT_TIMEOUT_NS
    localparam integer TB_TIMEOUT_NS = `TB_SHORT_TIMEOUT_NS;
`else
    localparam integer TB_TIMEOUT_NS = 20_000_000;
`endif
    localparam [39:0] CAL_TOKEN = 40'h43414C3D31; // "CAL=1"
    localparam [71:0] DDR3_PASS_TOKEN = 72'h444452332050415353; // "DDR3 PASS"

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
        count_u = 0;
        count_a = 0;
        count_r = 0;
        count_t = 0;
        count_d = 0;
        count_i = 0;
        count_g = 0;
        count_p = 0;
        count_s = 0;
        saw_space = 1'b0;
        saw_cr = 1'b0;
        saw_lf = 1'b0;
        saw_cal_token = 1'b0;
        saw_ddr3_pass_token = 1'b0;
        saw_ddr3_word = 1'b0;
        saw_uart_banner_chars = 1'b0;
        cal_shift = 40'd0;
        ddr3_pass_shift = 72'd0;
        #100;
        sys_rst_n = 1'b1;
    end

    always @(posedge core_uart_tx_start) begin
        if (core_uart_tx_start) begin
            uart_byte_count <= uart_byte_count + 1;
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
            cal_shift <= {cal_shift[31:0], core_uart_tx_byte};
            ddr3_pass_shift <= {ddr3_pass_shift[63:0], core_uart_tx_byte};

            if ({cal_shift[31:0], core_uart_tx_byte} == CAL_TOKEN) begin
                saw_cal_token <= 1'b1;
                $display("\n[AX7203_MAINLINE_DDR3] saw CAL=1 at byte %0d", uart_byte_count + 1);
            end
            if ({ddr3_pass_shift[63:0], core_uart_tx_byte} == DDR3_PASS_TOKEN) begin
                saw_ddr3_pass_token <= 1'b1;
                $display("\n[AX7203_MAINLINE_DDR3] saw DDR3 PASS at byte %0d", uart_byte_count + 1);
            end
            if ((core_uart_tx_byte == 8'h43) || (core_uart_tx_byte == 8'h4C) ||
                (core_uart_tx_byte == 8'h3D) || (core_uart_tx_byte == 8'h33) ||
                (core_uart_tx_byte == 8'h57) || (core_uart_tx_byte == 8'h42) ||
                (core_uart_tx_byte == 8'h45) || (core_uart_tx_byte == 8'h46)) begin
                saw_uart_banner_chars <= 1'b1;
            end

            case (core_uart_tx_byte)
                8'h55: count_u <= count_u + 1;
                8'h41: count_a <= count_a + 1;
                8'h52: count_r <= count_r + 1;
                8'h54: count_t <= count_t + 1;
                8'h44: count_d <= count_d + 1;
                8'h49: count_i <= count_i + 1;
                8'h47: count_g <= count_g + 1;
                8'h50: count_p <= count_p + 1;
                8'h53: count_s <= count_s + 1;
                8'h20: saw_space <= 1'b1;
                8'h0D: saw_cr <= 1'b1;
                8'h0A: saw_lf <= 1'b1;
                8'h42: ; // B
                8'h43: ; // C
                8'h45: ; // E
                8'h46: ; // F
                8'h4C: ; // L
                8'h33: ;
                8'h31: ;
                8'h3D: ;
                8'h57: ;
                default: ;
            endcase

            if (dut.u_mig.init_calib_complete && (dut.u_mig.mem[0][31:0] == 32'hDEADBEEF))
                saw_ddr3_word <= 1'b1;

            if (sys_rst_n &&
                dut.core_ready &&
                dut.core_retire_seen &&
                dut.mig_init_calib_complete &&
                (dut.tube_status == 8'h04) &&
                ((({cal_shift[31:0], core_uart_tx_byte} == CAL_TOKEN) || saw_cal_token) ||
                 (saw_uart_banner_chars && saw_ddr3_word)) &&
                ((({ddr3_pass_shift[63:0], core_uart_tx_byte} == DDR3_PASS_TOKEN) || saw_ddr3_pass_token) ||
                 saw_ddr3_word) &&
                ((core_uart_tx_byte == 8'h55 ? (count_u + 1) : count_u) >= 4) &&
                ((core_uart_tx_byte == 8'h41 ? (count_a + 1) : count_a) >= 12) &&
                ((core_uart_tx_byte == 8'h52 ? (count_r + 1) : count_r) >= 4) &&
                ((core_uart_tx_byte == 8'h54 ? (count_t + 1) : count_t) >= 4) &&
                ((core_uart_tx_byte == 8'h44 ? (count_d + 1) : count_d) >= 4) &&
                ((core_uart_tx_byte == 8'h49 ? (count_i + 1) : count_i) >= 4) &&
                ((core_uart_tx_byte == 8'h47 ? (count_g + 1) : count_g) >= 4) &&
                ((core_uart_tx_byte == 8'h50 ? (count_p + 1) : count_p) >= 4) &&
                ((core_uart_tx_byte == 8'h53 ? (count_s + 1) : count_s) >= 8) &&
                ((core_uart_tx_byte == 8'h20) || saw_space) &&
                ((core_uart_tx_byte == 8'h0D) || saw_cr) &&
                ((core_uart_tx_byte == 8'h0A) || saw_lf) &&
                (uart_byte_count + 1 >= 32)) begin
                $display("[AX7203_MAINLINE_DDR3] PASS ready=%0b retire=%0b calib=%0b tube=%0b cal_token=%0b ddr3_pass=%0b ddr3_word=%0b uart_bytes=%0d counts U=%0d A=%0d R=%0d T=%0d D=%0d I=%0d G=%0d P=%0d S=%0d led=%b",
                         dut.core_ready, dut.core_retire_seen, dut.mig_init_calib_complete,
                         dut.tube_status == 8'h04,
                         ({cal_shift[31:0], core_uart_tx_byte} == CAL_TOKEN || saw_cal_token),
                         ({ddr3_pass_shift[63:0], core_uart_tx_byte} == DDR3_PASS_TOKEN || saw_ddr3_pass_token),
                         saw_ddr3_word,
                         uart_byte_count + 1,
                         (core_uart_tx_byte == 8'h55 ? (count_u + 1) : count_u),
                         (core_uart_tx_byte == 8'h41 ? (count_a + 1) : count_a),
                         (core_uart_tx_byte == 8'h52 ? (count_r + 1) : count_r),
                         (core_uart_tx_byte == 8'h54 ? (count_t + 1) : count_t),
                         (core_uart_tx_byte == 8'h44 ? (count_d + 1) : count_d),
                         (core_uart_tx_byte == 8'h49 ? (count_i + 1) : count_i),
                         (core_uart_tx_byte == 8'h47 ? (count_g + 1) : count_g),
                         (core_uart_tx_byte == 8'h50 ? (count_p + 1) : count_p),
                         (core_uart_tx_byte == 8'h53 ? (count_s + 1) : count_s),
                         led);
                $finish;
            end
        end
    end

    initial begin : timeout_guard
        #TB_TIMEOUT_NS;
        $display("[AX7203_MAINLINE_DDR3] TIMEOUT ready=%0b retire=%0b calib=%0b tube=%0b cal_token=%0b ddr3_pass=%0b ddr3_word=%0b uart_bytes=%0d counts U=%0d A=%0d R=%0d T=%0d D=%0d I=%0d G=%0d P=%0d S=%0d led=%b",
                 dut.core_ready, dut.core_retire_seen, dut.mig_init_calib_complete,
                 dut.tube_status == 8'h04, saw_cal_token, saw_ddr3_pass_token, saw_ddr3_word,
                 uart_byte_count,
                 count_u, count_a, count_r, count_t, count_d, count_i, count_g, count_p, count_s,
                 led);
        $fatal(1);
    end

    initial begin : progress_trace
        forever begin
            #1_000_000;
            $display("[AX7203_MAINLINE_DDR3] PROGRESS t=%0t ready=%0b retire=%0b calib=%0b tube=%02h uart_bytes=%0d ddr3w0=%08h led=%b",
                     $time,
                     dut.core_ready,
                     dut.core_retire_seen,
                     dut.mig_init_calib_complete,
                     dut.tube_status,
                     uart_byte_count,
                     dut.u_mig.mem[0][31:0],
                     led);
`ifdef TB_VERBOSE
            $display("[AX7203_MAINLINE_DDR3] LSU lsu_state=%0d m1_req_v=%0b m1_req_r=%0b m1_resp_v=%0b m1_addr=%08h m1_wr=%0b uart_busy=%0b uart_pending=%0b sb_count0=%0d sb_count1=%0d",
                     dut.u_adam_riscv.u_lsu_shell.lsu_state,
                     dut.u_adam_riscv.u_lsu_shell.m1_req_valid,
                     dut.u_adam_riscv.u_lsu_shell.m1_req_ready,
                     dut.u_adam_riscv.u_lsu_shell.m1_resp_valid,
                     dut.u_adam_riscv.u_lsu_shell.m1_req_addr,
                     dut.u_adam_riscv.u_lsu_shell.m1_req_write,
                     dut.u_adam_riscv.gen_mem_subsys.u_mem_subsys.uart_busy,
                     dut.u_adam_riscv.gen_mem_subsys.u_mem_subsys.uart_pending_valid_r,
                     dut.u_adam_riscv.u_lsu_shell.u_store_buffer.sb_count[0],
                     dut.u_adam_riscv.u_lsu_shell.u_store_buffer.sb_count[1]);
            $display("[AX7203_MAINLINE_DDR3] PC t0=%08h t1=%08h fetch_pc=%08h fetch_tid=%0d issue0_pc_lo=%02h issue1_pc_lo=%02h",
                     dut.u_adam_riscv.u_stage_if.u_pc_mt.pc[0],
                     dut.u_adam_riscv.u_stage_if.u_pc_mt.pc[1],
                     dut.u_adam_riscv.u_stage_if.fetch_pc_pending,
                     dut.u_adam_riscv.u_stage_if.fetch_tid_pending,
                     dut.u_adam_riscv.debug_last_iss0_pc_lo,
                     dut.u_adam_riscv.debug_last_iss1_pc_lo);
            $display("[AX7203_MAINLINE_DDR3] DDR3 core_req_v=%0b core_req_r=%0b core_req_addr=%08h core_req_wr=%0b core_resp_v=%0b ui_state=%0d req_pend=%0b req_pend_ui=%0b awv=%0b awr=%0b wv=%0b wr=%0b bv=%0b arv=%0b arr=%0b rv=%0b",
                     dut.core_ddr3_req_valid,
                     dut.core_ddr3_req_ready,
                     dut.core_ddr3_req_addr,
                     dut.core_ddr3_req_write,
                     dut.core_ddr3_resp_valid,
                     dut.u_ddr3_mem_port.ui_state,
                     dut.u_ddr3_mem_port.req_pending,
                     dut.u_ddr3_mem_port.req_pending_ui,
                     dut.mig_s_axi_awvalid,
                     dut.mig_s_axi_awready,
                     dut.mig_s_axi_wvalid,
                     dut.mig_s_axi_wready,
                     dut.mig_s_axi_bvalid,
                     dut.mig_s_axi_arvalid,
                     dut.mig_s_axi_arready,
                     dut.mig_s_axi_rvalid);
`endif
        end
    end

    always @(posedge dut.core_ddr3_req_valid) begin
        $display("[AX7203_MAINLINE_DDR3] DDR3_REQ t=%0t addr=%08h wr=%0b wdata=%08h wen=%0h ready=%0b",
                 $time,
                 dut.core_ddr3_req_addr,
                 dut.core_ddr3_req_write,
                 dut.core_ddr3_req_wdata,
                 dut.core_ddr3_req_wen,
                 dut.core_ddr3_req_ready);
    end

    always @(posedge dut.mig_s_axi_awvalid) begin
        $display("[AX7203_MAINLINE_DDR3] AXI_AW t=%0t addr=%08h ready=%0b",
                 $time,
                 dut.mig_s_axi_awaddr,
                 dut.mig_s_axi_awready);
    end

    always @(posedge dut.mig_s_axi_wvalid) begin
        $display("[AX7203_MAINLINE_DDR3] AXI_W t=%0t strb=%08h data_lo=%08h ready=%0b",
                 $time,
                 dut.mig_s_axi_wstrb,
                 dut.mig_s_axi_wdata[31:0],
                 dut.mig_s_axi_wready);
    end

    always @(posedge dut.mig_s_axi_bvalid) begin
        $display("[AX7203_MAINLINE_DDR3] AXI_B t=%0t resp=%0h",
                 $time,
                 dut.mig_s_axi_bresp);
    end

    always @(posedge dut.mig_s_axi_arvalid) begin
        $display("[AX7203_MAINLINE_DDR3] AXI_AR t=%0t addr=%08h ready=%0b",
                 $time,
                 dut.mig_s_axi_araddr,
                 dut.mig_s_axi_arready);
    end

    always @(posedge dut.mig_s_axi_rvalid) begin
        $display("[AX7203_MAINLINE_DDR3] AXI_R t=%0t data_lo=%08h resp=%0h",
                 $time,
                 dut.mig_s_axi_rdata[31:0],
                 dut.mig_s_axi_rresp);
    end

    always @(posedge dut.core_ddr3_resp_valid) begin
        $display("[AX7203_MAINLINE_DDR3] DDR3_RESP t=%0t data=%08h",
                 $time,
                 dut.core_ddr3_resp_data);
    end

    always @(posedge dut.u_adam_riscv.u_lsu_shell.m1_resp_valid) begin
`ifdef TB_VERBOSE
        $display("[AX7203_MAINLINE_DDR3] LSU_M1_RESP t=%0t data=%08h pending_addr=%08h pending_func3=%0d raw=%08h",
                 $time,
                 dut.u_adam_riscv.u_lsu_shell.m1_resp_data,
                 dut.u_adam_riscv.u_lsu_shell.pending_addr,
                 dut.u_adam_riscv.u_lsu_shell.pending_func3,
                 dut.u_adam_riscv.u_lsu_shell.raw_mem_rdata);
`endif
    end

endmodule
