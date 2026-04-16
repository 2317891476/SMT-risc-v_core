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
`else
    localparam integer UART_BIT_NS = 8680;
`endif
`ifdef TB_SHORT_TIMEOUT_NS
    localparam integer TB_TIMEOUT_NS = `TB_SHORT_TIMEOUT_NS;
`else
    localparam integer TB_TIMEOUT_NS = 80_000_000;
`endif
    localparam integer MAX_PAYLOAD_BYTES = 4096;
    localparam [119:0] READY_TOKEN = 120'h424F4F542044445233205245414459; // BOOT DDR3 READY
    localparam [79:0] LOAD_START_TOKEN = 80'h4C4F4144205354415254; // LOAD START
    localparam [55:0] LOAD_OK_TOKEN = 56'h4C4F4144204F4B; // LOAD OK
    localparam [111:0] EXEC_PASS_TOKEN = 112'h4444523320455845432050415353; // DDR3 EXEC PASS
    localparam [7:0] LOADER_ACK_BYTE = 8'h06;

    reg [7:0] payload [0:MAX_PAYLOAD_BYTES-1];
    integer payload_size;
    integer payload_checksum;
    integer payload_idx;
    integer sent_header;
    integer sent_payload;
    integer uart_byte_count;
    reg saw_ready;
    reg saw_load_start;
    reg saw_load_ok;
    reg saw_exec_pass;
    reg [127:0] shift128;
    event payload_ack_event;

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
            send_u32_le(32'h314B4D42);       // "BMK1" little-endian
            send_u32_le(32'h80000000);       // load address
            send_u32_le(32'h80000000);       // entry
            send_u32_le(payload_size[31:0]);
            send_u32_le(payload_checksum[31:0]);
        end
    endtask

    task automatic send_payload_bytes;
        begin
            for (payload_idx = 0; payload_idx < payload_size; payload_idx = payload_idx + 1) begin
                send_uart_byte(payload[payload_idx]);
            end
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
            $display("[AX7203_DDR3_LOADER] bad payload_size=%0d", payload_size);
            $fatal(1);
        end
        $readmemh("ddr3_loader_payload.hex", payload);

        sys_rst_n = 1'b0;
        uart_rx = 1'b1;
        sent_header = 0;
        sent_payload = 0;
        uart_byte_count = 0;
        saw_ready = 1'b0;
        saw_load_start = 1'b0;
        saw_load_ok = 1'b0;
        saw_exec_pass = 1'b0;
        shift128 = 128'd0;
        #100;
        sys_rst_n = 1'b1;
    end

    initial begin : uart_host_driver
        wait(sys_rst_n == 1'b1);
        wait(saw_ready == 1'b1);
        #(UART_BIT_NS * 40);
        $display("[AX7203_DDR3_LOADER_TB] send header");
        sent_header = 1;
        send_header_frame();
        wait(saw_load_start == 1'b1);
        #(UART_BIT_NS * 40);
        sent_payload = 1;
        payload_idx = 0;
        while (payload_idx < payload_size) begin
            $display("[AX7203_DDR3_LOADER_TB] send chunk start_idx=%0d", payload_idx);
            send_payload_chunk();
            if (payload_idx < payload_size) begin
                @payload_ack_event;
                #(UART_BIT_NS * 4);
            end
        end
    end

    always @(posedge core_uart_tx_start) begin
        uart_byte_count <= uart_byte_count + 1;
        shift128 <= {shift128[119:0], core_uart_tx_byte};
        if (core_uart_tx_byte >= 8'h20 && core_uart_tx_byte <= 8'h7e)
            $write("%c", core_uart_tx_byte);
        else if (core_uart_tx_byte == 8'h0d)
            $write("<CR>");
        else if (core_uart_tx_byte == 8'h0a)
            $write("<LF>\n");

        if ({shift128[111:0], core_uart_tx_byte} == READY_TOKEN)
            saw_ready <= 1'b1;
        if ({shift128[71:0], core_uart_tx_byte} == LOAD_START_TOKEN)
            saw_load_start <= 1'b1;
        if ((core_uart_tx_byte == LOADER_ACK_BYTE) && (sent_payload != 0))
            -> payload_ack_event;
        if ({shift128[47:0], core_uart_tx_byte} == LOAD_OK_TOKEN)
            saw_load_ok <= 1'b1;
        if ({shift128[103:0], core_uart_tx_byte} == EXEC_PASS_TOKEN)
            saw_exec_pass <= 1'b1;
        if (dut.tube_status == 8'h04)
            saw_exec_pass <= 1'b1;
    end

    initial begin : timeout_guard
        #TB_TIMEOUT_NS;
        $display("[AX7203_DDR3_LOADER] TIMEOUT ready=%0b load_ok=%0b exec_pass=%0b sent_header=%0d sent_payload=%0d payload_idx=%0d uart_bytes=%0d tube=%02h led=%b",
                 saw_ready, saw_load_ok, saw_exec_pass, sent_header, sent_payload, payload_idx, uart_byte_count,
                 dut.tube_status, led);
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
        $fatal(1);
    end

    always @(posedge sys_clk_p) begin
        if (dut.tube_status == 8'h04)
            saw_exec_pass <= 1'b1;
        if (sys_rst_n && saw_ready && saw_load_ok && saw_exec_pass && dut.tube_status == 8'h04) begin
            $display("[AX7203_DDR3_LOADER] PASS ready=%0b load_ok=%0b exec_pass=%0b uart_bytes=%0d tube=%02h led=%b",
                     saw_ready, saw_load_ok, saw_exec_pass, uart_byte_count, dut.tube_status, led);
            $finish;
        end
    end
endmodule
