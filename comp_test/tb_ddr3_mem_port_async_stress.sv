`timescale 1ns/1ps

module tb_ddr3_mem_port_async_stress;
    localparam integer AXI_DATA_W = 256;
    localparam integer AXI_ADDR_W = 30;
    localparam integer AXI_ID_W   = 4;
    localparam integer MEM_LINES  = 512;
    localparam integer MEM_WORDS  = MEM_LINES * 8;
    localparam integer CALIB_CYCLES = 16;

    integer core_clk_ns;
    integer ui_clk_ns;
    integer stall_pct;
    integer resp_latency_min;
    integer resp_latency_max;
    integer op_count;
    integer test_seed;

    reg core_clk;
    reg ui_clk;
    reg core_rstn;
    reg ui_rstn;
    reg init_calib_complete;

    reg        req_valid;
    wire       req_ready;
    reg [31:0] req_addr;
    reg        req_write;
    reg [31:0] req_wdata;
    reg [3:0]  req_wen;
    wire       resp_valid;
    wire [31:0] resp_data;

    wire                      m_axi_awvalid;
    reg                       m_axi_awready;
    wire [AXI_ID_W-1:0]       m_axi_awid;
    wire [AXI_ADDR_W-1:0]     m_axi_awaddr;
    wire [7:0]                m_axi_awlen;
    wire [2:0]                m_axi_awsize;
    wire [1:0]                m_axi_awburst;
    wire                      m_axi_awlock;
    wire [3:0]                m_axi_awcache;
    wire [2:0]                m_axi_awprot;
    wire [3:0]                m_axi_awqos;
    wire                      m_axi_wvalid;
    reg                       m_axi_wready;
    wire [AXI_DATA_W-1:0]     m_axi_wdata;
    wire [AXI_DATA_W/8-1:0]   m_axi_wstrb;
    wire                      m_axi_wlast;
    reg                       m_axi_bvalid;
    wire                      m_axi_bready;
    reg  [AXI_ID_W-1:0]       m_axi_bid;
    reg  [1:0]                m_axi_bresp;
    wire                      m_axi_arvalid;
    reg                       m_axi_arready;
    wire [AXI_ID_W-1:0]       m_axi_arid;
    wire [AXI_ADDR_W-1:0]     m_axi_araddr;
    wire [7:0]                m_axi_arlen;
    wire [2:0]                m_axi_arsize;
    wire [1:0]                m_axi_arburst;
    wire                      m_axi_arlock;
    wire [3:0]                m_axi_arcache;
    wire [2:0]                m_axi_arprot;
    wire [3:0]                m_axi_arqos;
    reg                       m_axi_rvalid;
    wire                      m_axi_rready;
    reg  [AXI_ID_W-1:0]       m_axi_rid;
    reg  [AXI_DATA_W-1:0]     m_axi_rdata;
    reg  [1:0]                m_axi_rresp;
    reg                       m_axi_rlast;

    reg [255:0] mem [0:MEM_LINES-1];
    reg [31:0]  expected_words [0:MEM_WORDS-1];

    integer calib_ctr;
    integer idx;
    integer byte_idx;
    integer op_idx;
    integer pass_reads;
    integer pass_writes;
    integer case_errors;
    integer seed_warmup;

    reg        aw_seen_r;
    reg [31:0] aw_addr_r;
    reg [3:0]  aw_id_r;
    reg        w_seen_r;
    reg [255:0] w_data_r;
    reg [31:0] w_strb_r;
    reg        b_pending_r;
    integer    b_latency_r;

    reg        r_pending_r;
    reg [31:0] ar_addr_r;
    reg [3:0]  ar_id_r;
    integer    r_latency_r;

    function automatic integer line_index(input [31:0] addr);
        begin
            line_index = addr[13:5];
        end
    endfunction

    function automatic integer word_index(input [31:0] addr);
        begin
            word_index = addr[13:2];
        end
    endfunction

    function automatic [31:0] apply_byte_wen(
        input [31:0] old_word,
        input [31:0] new_word,
        input [3:0]  wen
    );
        reg [31:0] tmp;
        begin
            tmp = old_word;
            if (wen[0]) tmp[7:0]   = new_word[7:0];
            if (wen[1]) tmp[15:8]  = new_word[15:8];
            if (wen[2]) tmp[23:16] = new_word[23:16];
            if (wen[3]) tmp[31:24] = new_word[31:24];
            apply_byte_wen = tmp;
        end
    endfunction

    function automatic integer rand_pct_ok(input integer pct);
        begin
            rand_pct_ok = ($urandom_range(99) >= pct);
        end
    endfunction

    function automatic integer rand_latency(input integer min_v, input integer max_v);
        begin
            if (max_v <= min_v)
                rand_latency = min_v;
            else
                rand_latency = $urandom_range(max_v, min_v);
        end
    endfunction

    task automatic model_word_write(
        input [31:0] addr,
        input [31:0] data,
        input [3:0]  wen
    );
        integer widx;
        begin
            widx = word_index(addr);
            expected_words[widx] = apply_byte_wen(expected_words[widx], data, wen);
        end
    endtask

    task automatic drive_request(
        input        is_write,
        input [31:0] addr,
        input [31:0] wdata,
        input [3:0]  wen,
        output [31:0] rdata
    );
        integer timeout;
        begin
            timeout = 0;
            while (!req_ready) begin
                @(posedge core_clk);
                timeout = timeout + 1;
                if (timeout > 4000) begin
                    $display("[DDR3_BRIDGE_TB] core-side req_ready timeout addr=%08h wr=%0b pending=%0b ui_state=%0d",
                             addr, is_write, dut.req_pending, dut.ui_state);
                    $fatal(1);
                end
            end

            @(negedge core_clk);
            req_addr  <= addr;
            req_write <= is_write;
            req_wdata <= wdata;
            req_wen   <= wen;
            req_valid <= 1'b1;

            @(posedge core_clk);

            @(negedge core_clk);
            req_valid <= 1'b0;
            req_addr  <= 32'd0;
            req_write <= 1'b0;
            req_wdata <= 32'd0;
            req_wen   <= 4'd0;

            timeout = 0;
            while (!resp_valid) begin
                @(posedge core_clk);
                timeout = timeout + 1;
                if (timeout > 8000) begin
                    $display("[DDR3_BRIDGE_TB] resp timeout addr=%08h wr=%0b debug core_acc=%0d ui_cons=%0d ar=%0d r=%0d aw=%0d w=%0d b=%0d resp=%0d flags timeout=%0b stuck=%0b dup=%0b last_req=%08h/%0b last_resp=%08h",
                             addr,
                             is_write,
                             dut.debug_core_req_accept_count_r,
                             dut.debug_ui_req_consume_count_r,
                             dut.debug_axi_ar_count_r,
                             dut.debug_axi_r_count_r,
                             dut.debug_axi_aw_count_r,
                             dut.debug_axi_w_count_r,
                             dut.debug_axi_b_count_r,
                             dut.debug_resp_toggle_count_r,
                             dut.debug_req_pending_timeout_flag_r,
                             dut.debug_ui_state_stuck_flag_r,
                             dut.debug_duplicate_resp_flag_r,
                             dut.debug_last_req_addr_r,
                             dut.debug_last_req_write_r,
                             dut.debug_last_resp_data_r);
                    $fatal(1);
                end
            end
            rdata = resp_data;
            @(posedge core_clk);
        end
    endtask

    task automatic expect_read(input [31:0] addr);
        reg [31:0] got;
        reg [31:0] exp;
        begin
            drive_request(1'b0, addr, 32'd0, 4'd0, got);
            exp = expected_words[word_index(addr)];
            if (got !== exp) begin
                case_errors = case_errors + 1;
                $display("[DDR3_BRIDGE_TB] READ MISMATCH addr=%08h exp=%08h got=%08h word_idx=%0d",
                         addr, exp, got, word_index(addr));
                $fatal(1);
            end
            pass_reads = pass_reads + 1;
        end
    endtask

    task automatic do_write(
        input [31:0] addr,
        input [31:0] data,
        input [3:0]  wen
    );
        reg [31:0] unused_resp;
        begin
            drive_request(1'b1, addr, data, wen, unused_resp);
            model_word_write(addr, data, wen);
            pass_writes = pass_writes + 1;
        end
    endtask

    ddr3_mem_port #(
        .AXI_DATA_W(AXI_DATA_W),
        .AXI_ADDR_W(AXI_ADDR_W),
        .AXI_ID_W  (AXI_ID_W)
    ) dut (
        .core_clk            (core_clk),
        .core_rstn           (core_rstn),
        .req_valid           (req_valid),
        .req_ready           (req_ready),
        .req_addr            (req_addr),
        .req_write           (req_write),
        .req_wdata           (req_wdata),
        .req_wen             (req_wen),
        .resp_valid          (resp_valid),
        .resp_data           (resp_data),
        .ui_clk              (ui_clk),
        .ui_rstn             (ui_rstn),
        .init_calib_complete (init_calib_complete),
        .m_axi_awvalid       (m_axi_awvalid),
        .m_axi_awready       (m_axi_awready),
        .m_axi_awid          (m_axi_awid),
        .m_axi_awaddr        (m_axi_awaddr),
        .m_axi_awlen         (m_axi_awlen),
        .m_axi_awsize        (m_axi_awsize),
        .m_axi_awburst       (m_axi_awburst),
        .m_axi_awlock        (m_axi_awlock),
        .m_axi_awcache       (m_axi_awcache),
        .m_axi_awprot        (m_axi_awprot),
        .m_axi_awqos         (m_axi_awqos),
        .m_axi_wvalid        (m_axi_wvalid),
        .m_axi_wready        (m_axi_wready),
        .m_axi_wdata         (m_axi_wdata),
        .m_axi_wstrb         (m_axi_wstrb),
        .m_axi_wlast         (m_axi_wlast),
        .m_axi_bvalid        (m_axi_bvalid),
        .m_axi_bready        (m_axi_bready),
        .m_axi_bid           (m_axi_bid),
        .m_axi_bresp         (m_axi_bresp),
        .m_axi_arvalid       (m_axi_arvalid),
        .m_axi_arready       (m_axi_arready),
        .m_axi_arid          (m_axi_arid),
        .m_axi_araddr        (m_axi_araddr),
        .m_axi_arlen         (m_axi_arlen),
        .m_axi_arsize        (m_axi_arsize),
        .m_axi_arburst       (m_axi_arburst),
        .m_axi_arlock        (m_axi_arlock),
        .m_axi_arcache       (m_axi_arcache),
        .m_axi_arprot        (m_axi_arprot),
        .m_axi_arqos         (m_axi_arqos),
        .m_axi_rvalid        (m_axi_rvalid),
        .m_axi_rready        (m_axi_rready),
        .m_axi_rid           (m_axi_rid),
        .m_axi_rdata         (m_axi_rdata),
        .m_axi_rresp         (m_axi_rresp),
        .m_axi_rlast         (m_axi_rlast)
    );

    initial begin
        if (!$value$plusargs("CORE_CLK_NS=%d", core_clk_ns))
            core_clk_ns = 40;
        if (!$value$plusargs("UI_CLK_NS=%d", ui_clk_ns))
            ui_clk_ns = 10;
        if (!$value$plusargs("AXI_STALL_PCT=%d", stall_pct))
            stall_pct = 35;
        if (!$value$plusargs("RESP_LAT_MIN=%d", resp_latency_min))
            resp_latency_min = 1;
        if (!$value$plusargs("RESP_LAT_MAX=%d", resp_latency_max))
            resp_latency_max = 6;
        if (!$value$plusargs("OP_COUNT=%d", op_count))
            op_count = 256;
        if (!$value$plusargs("TEST_SEED=%d", test_seed))
            test_seed = 1;

        seed_warmup = $urandom(test_seed);
    end

    initial begin
        core_clk = 1'b0;
        forever #(core_clk_ns / 2) core_clk = ~core_clk;
    end

    initial begin
        ui_clk = 1'b0;
        forever #(ui_clk_ns / 2) ui_clk = ~ui_clk;
    end

    initial begin
        core_rstn = 1'b0;
        ui_rstn = 1'b0;
        init_calib_complete = 1'b0;
        req_valid = 1'b0;
        req_addr = 32'd0;
        req_write = 1'b0;
        req_wdata = 32'd0;
        req_wen = 4'd0;

        m_axi_awready = 1'b0;
        m_axi_wready = 1'b0;
        m_axi_bvalid = 1'b0;
        m_axi_bid = {AXI_ID_W{1'b0}};
        m_axi_bresp = 2'b00;
        m_axi_arready = 1'b0;
        m_axi_rvalid = 1'b0;
        m_axi_rid = {AXI_ID_W{1'b0}};
        m_axi_rdata = {AXI_DATA_W{1'b0}};
        m_axi_rresp = 2'b00;
        m_axi_rlast = 1'b0;

        aw_seen_r = 1'b0;
        aw_addr_r = 32'd0;
        aw_id_r = {AXI_ID_W{1'b0}};
        w_seen_r = 1'b0;
        w_data_r = {AXI_DATA_W{1'b0}};
        w_strb_r = 32'd0;
        b_pending_r = 1'b0;
        b_latency_r = 0;
        r_pending_r = 1'b0;
        ar_addr_r = 32'd0;
        ar_id_r = {AXI_ID_W{1'b0}};
        r_latency_r = 0;

        calib_ctr = 0;
        pass_reads = 0;
        pass_writes = 0;
        case_errors = 0;

        for (idx = 0; idx < MEM_LINES; idx = idx + 1)
            mem[idx] = 256'd0;
        for (idx = 0; idx < MEM_WORDS; idx = idx + 1)
            expected_words[idx] = 32'd0;

        repeat (8) @(posedge core_clk);
        core_rstn = 1'b1;
        repeat (8) @(posedge ui_clk);
        ui_rstn = 1'b1;
    end

    always @(posedge ui_clk or negedge ui_rstn) begin
        if (!ui_rstn) begin
            init_calib_complete <= 1'b0;
            calib_ctr <= 0;
        end else if (!init_calib_complete) begin
            calib_ctr <= calib_ctr + 1;
            if (calib_ctr >= CALIB_CYCLES)
                init_calib_complete <= 1'b1;
        end
    end

    always @(posedge ui_clk or negedge ui_rstn) begin
        if (!ui_rstn) begin
            m_axi_awready <= 1'b0;
            m_axi_wready  <= 1'b0;
            m_axi_arready <= 1'b0;
            m_axi_bvalid  <= 1'b0;
            m_axi_rvalid  <= 1'b0;
            m_axi_rlast   <= 1'b0;
            aw_seen_r     <= 1'b0;
            w_seen_r      <= 1'b0;
            b_pending_r   <= 1'b0;
            b_latency_r   <= 0;
            r_pending_r   <= 1'b0;
            r_latency_r   <= 0;
        end else begin
            m_axi_awready <= init_calib_complete && rand_pct_ok(stall_pct);
            m_axi_wready  <= init_calib_complete && rand_pct_ok(stall_pct);
            m_axi_arready <= init_calib_complete && !r_pending_r && !m_axi_rvalid && rand_pct_ok(stall_pct);

            if (m_axi_bvalid && m_axi_bready)
                m_axi_bvalid <= 1'b0;
            if (m_axi_rvalid && m_axi_rready) begin
                m_axi_rvalid <= 1'b0;
                m_axi_rlast  <= 1'b0;
            end

            if (m_axi_awvalid && m_axi_awready && !aw_seen_r) begin
                aw_seen_r <= 1'b1;
                aw_addr_r <= m_axi_awaddr;
                aw_id_r   <= m_axi_awid;
            end

            if (m_axi_wvalid && m_axi_wready && !w_seen_r) begin
                w_seen_r <= 1'b1;
                w_data_r <= m_axi_wdata;
                w_strb_r <= m_axi_wstrb;
            end

            if (aw_seen_r && w_seen_r && !b_pending_r) begin
                for (byte_idx = 0; byte_idx < 32; byte_idx = byte_idx + 1) begin
                    if (w_strb_r[byte_idx])
                        mem[line_index(aw_addr_r)][byte_idx*8 +: 8] <= w_data_r[byte_idx*8 +: 8];
                end
                b_pending_r <= 1'b1;
                b_latency_r <= rand_latency(resp_latency_min, resp_latency_max);
                aw_seen_r   <= 1'b0;
                w_seen_r    <= 1'b0;
            end else if (b_pending_r && !m_axi_bvalid) begin
                if (b_latency_r <= 0) begin
                    m_axi_bvalid <= 1'b1;
                    m_axi_bid    <= aw_id_r;
                    m_axi_bresp  <= 2'b00;
                    b_pending_r  <= 1'b0;
                end else begin
                    b_latency_r <= b_latency_r - 1;
                end
            end

            if (m_axi_arvalid && m_axi_arready && !r_pending_r && !m_axi_rvalid) begin
                r_pending_r <= 1'b1;
                ar_addr_r   <= m_axi_araddr;
                ar_id_r     <= m_axi_arid;
                r_latency_r <= rand_latency(resp_latency_min, resp_latency_max);
            end else if (r_pending_r && !m_axi_rvalid) begin
                if (r_latency_r <= 0) begin
                    m_axi_rvalid <= 1'b1;
                    m_axi_rid    <= ar_id_r;
                    m_axi_rdata  <= mem[line_index(ar_addr_r)];
                    m_axi_rresp  <= 2'b00;
                    m_axi_rlast  <= 1'b1;
                    r_pending_r  <= 1'b0;
                end else begin
                    r_latency_r <= r_latency_r - 1;
                end
            end
        end
    end

    initial begin : test_sequence
        reg [31:0] base_addr;
        reg [31:0] rand_addr;
        reg [31:0] rand_data;
        reg [3:0]  rand_wen;
        integer    rand_word;
        wait(core_rstn && ui_rstn && init_calib_complete);
        repeat (8) @(posedge core_clk);

        base_addr = 32'h8000_0000;

        for (idx = 0; idx < 8; idx = idx + 1)
            do_write(base_addr + (idx * 4), 32'hA500_0000 | (idx << 8) | idx, 4'hF);
        for (idx = 0; idx < 8; idx = idx + 1)
            expect_read(base_addr + (idx * 4));

        do_write(base_addr + 32'd12, 32'h1122_3344, 4'b0011);
        do_write(base_addr + 32'd12, 32'hAABB_CCDD, 4'b1100);
        expect_read(base_addr + 32'd12);

        for (idx = 0; idx < 8; idx = idx + 1)
            do_write(base_addr + 32'd32 + (idx * 4), 32'h5A00_0000 | (idx << 16) | (32'h55 + idx), 4'hF);
        for (idx = 0; idx < 8; idx = idx + 1)
            expect_read(base_addr + 32'd32 + (idx * 4));

        for (op_idx = 0; op_idx < op_count; op_idx = op_idx + 1) begin
            rand_word = $urandom_range(255);
            rand_addr = base_addr + (rand_word * 4);
            if (($urandom_range(99) < 60)) begin
                rand_data = $urandom();
                rand_wen = $urandom_range(15, 1);
                do_write(rand_addr, rand_data, rand_wen);
                if (($urandom_range(99) < 35))
                    expect_read(rand_addr);
            end else begin
                expect_read(rand_addr);
            end
        end

        for (idx = 0; idx < 256; idx = idx + 1)
            expect_read(base_addr + (idx * 4));

        if (dut.debug_req_pending_timeout_flag_r ||
            dut.debug_ui_state_stuck_flag_r ||
            dut.debug_duplicate_resp_flag_r) begin
            $display("[DDR3_BRIDGE_TB] DEBUG FLAG FAIL timeout=%0b stuck=%0b dup=%0b",
                     dut.debug_req_pending_timeout_flag_r,
                     dut.debug_ui_state_stuck_flag_r,
                     dut.debug_duplicate_resp_flag_r);
            $fatal(1);
        end

        if (dut.debug_core_req_accept_count_r != dut.debug_ui_req_consume_count_r ||
            dut.debug_core_req_accept_count_r != dut.debug_resp_toggle_count_r) begin
            $display("[DDR3_BRIDGE_TB] COUNT FAIL core_acc=%0d ui_cons=%0d resp=%0d ar=%0d r=%0d aw=%0d w=%0d b=%0d",
                     dut.debug_core_req_accept_count_r,
                     dut.debug_ui_req_consume_count_r,
                     dut.debug_resp_toggle_count_r,
                     dut.debug_axi_ar_count_r,
                     dut.debug_axi_r_count_r,
                     dut.debug_axi_aw_count_r,
                     dut.debug_axi_w_count_r,
                     dut.debug_axi_b_count_r);
            $fatal(1);
        end

        if (dut.debug_axi_ar_count_r != dut.debug_axi_r_count_r ||
            dut.debug_axi_aw_count_r != dut.debug_axi_w_count_r ||
            dut.debug_axi_aw_count_r != dut.debug_axi_b_count_r) begin
            $display("[DDR3_BRIDGE_TB] AXI COUNT FAIL ar=%0d r=%0d aw=%0d w=%0d b=%0d",
                     dut.debug_axi_ar_count_r,
                     dut.debug_axi_r_count_r,
                     dut.debug_axi_aw_count_r,
                     dut.debug_axi_w_count_r,
                     dut.debug_axi_b_count_r);
            $fatal(1);
        end

        $display("[DDR3_BRIDGE_TB] PASS core_clk_ns=%0d ui_clk_ns=%0d stall_pct=%0d seed=%0d writes=%0d reads=%0d core_acc=%0d ui_cons=%0d ar=%0d r=%0d aw=%0d w=%0d b=%0d last_req=%08h/%0b last_resp=%08h",
                 core_clk_ns, ui_clk_ns, stall_pct, test_seed,
                 pass_writes, pass_reads,
                 dut.debug_core_req_accept_count_r,
                 dut.debug_ui_req_consume_count_r,
                 dut.debug_axi_ar_count_r,
                 dut.debug_axi_r_count_r,
                 dut.debug_axi_aw_count_r,
                 dut.debug_axi_w_count_r,
                 dut.debug_axi_b_count_r,
                 dut.debug_last_req_addr_r,
                 dut.debug_last_req_write_r,
                 dut.debug_last_resp_data_r);
        $finish;
    end

    initial begin : timeout_guard
        #5_000_000;
        $display("[DDR3_BRIDGE_TB] TIMEOUT core_acc=%0d ui_cons=%0d ar=%0d r=%0d aw=%0d w=%0d b=%0d resp=%0d flags timeout=%0b stuck=%0b dup=%0b last_req=%08h/%0b last_resp=%08h",
                 dut.debug_core_req_accept_count_r,
                 dut.debug_ui_req_consume_count_r,
                 dut.debug_axi_ar_count_r,
                 dut.debug_axi_r_count_r,
                 dut.debug_axi_aw_count_r,
                 dut.debug_axi_w_count_r,
                 dut.debug_axi_b_count_r,
                 dut.debug_resp_toggle_count_r,
                 dut.debug_req_pending_timeout_flag_r,
                 dut.debug_ui_state_stuck_flag_r,
                 dut.debug_duplicate_resp_flag_r,
                 dut.debug_last_req_addr_r,
                 dut.debug_last_req_write_r,
                 dut.debug_last_resp_data_r);
        $fatal(1);
    end
endmodule
