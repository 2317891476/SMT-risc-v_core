`ifndef FPGA_MODE
    `define FPGA_MODE 1
`endif

module adam_riscv_ax7203_status_top (
    input  wire sys_clk_p,
    input  wire sys_clk_n,
    input  wire sys_rst_n,
    output wire uart_tx,
    input  wire uart_rx,
    output wire [4:0] led
);

wire sys_clk_200m;

IBUFGDS clk_ibufgds (
    .O  (sys_clk_200m),
    .I  (sys_clk_p   ),
    .IB (sys_clk_n   )
);

reg [15:0] por_cnt;
reg por_rst_n;
wire core_rst_n;

always @(posedge sys_clk_200m) begin
    if (por_cnt != 16'hFFFF) begin
        por_cnt   <= por_cnt + 16'd1;
        por_rst_n <= 1'b0;
    end else begin
        por_rst_n <= 1'b1;
    end
end

initial begin
    por_cnt = 16'd0;
    por_rst_n = 1'b0;
end

assign core_rst_n = por_rst_n;

wire [2:0] core_led;
wire [7:0] tube_status;
wire       core_uart_tx;
wire       core_ready;
wire       core_retire_seen;
wire       debug_uart_status_busy;
wire       debug_uart_busy;
wire       debug_uart_pending_valid;
wire [7:0] debug_uart_status_load_count;
wire [7:0] debug_uart_tx_store_count;
wire [7:0] debug_last_iss0_pc_lo;
wire [7:0] debug_last_iss1_pc_lo;
wire       debug_branch_pending_any;
wire       debug_br_found_t0;
wire       debug_branch_in_flight_t0;
wire       debug_oldest_br_ready_t0;
wire       debug_oldest_br_just_woke_t0;
wire [3:0] debug_oldest_br_qj_t0;
wire [3:0] debug_oldest_br_qk_t0;
wire [3:0] debug_slot1_flags;
wire [7:0] debug_slot1_pc_lo;
wire [3:0] debug_slot1_qj;
wire [3:0] debug_slot1_qk;
wire [3:0] debug_tag2_flags;
wire [3:0] debug_reg_x12_tag_t0;
wire [3:0] debug_slot1_issue_flags;
wire [3:0] debug_sel0_idx;
wire [3:0] debug_slot1_fu;
wire [7:0] debug_branch_issue_count;
wire [7:0] debug_branch_complete_count;
wire       core_uart_frame_seen;
wire [3:0] core_uart_frame_count;
wire [7:0] core_uart_frame_count_rolling;
wire       bridged_uart_tx;
wire       bridge_uart_frame_seen;
wire [3:0] bridge_uart_frame_count;
wire [7:0] bridge_uart_frame_count_rolling;
wire       core_uart_byte_valid;
wire [7:0] core_uart_byte;
wire       bridge_uart_busy;
wire [3:0] status_uart_frame_count;
wire       status_uart_tx;
reg  [1:0] core_uart_sync;
reg        core_uart_seen;
reg        bridge_tx_start;
reg [7:0]  bridge_tx_data;
reg        bridge_pending_valid;
reg [7:0]  bridge_pending_byte;
wire       core_uart_edge = core_uart_sync[1] ^ core_uart_sync[0];

(* DONT_TOUCH = "TRUE", KEEP_HIERARCHY = "TRUE" *)
adam_riscv u_adam_riscv (
    .sys_clk          (sys_clk_200m     ),
    .sys_rstn         (core_rst_n       ),
    .ext_irq_src      (1'b0             ),
    .led              (core_led         ),
    .tube_status      (tube_status      ),
    .uart_tx          (core_uart_tx     ),
    .debug_core_ready (core_ready       ),
    .debug_retire_seen(core_retire_seen ),
    .debug_uart_status_busy(debug_uart_status_busy),
    .debug_uart_busy(debug_uart_busy),
    .debug_uart_pending_valid(debug_uart_pending_valid),
    .debug_uart_status_load_count(debug_uart_status_load_count),
    .debug_uart_tx_store_count(debug_uart_tx_store_count),
    .debug_last_iss0_pc_lo(debug_last_iss0_pc_lo),
    .debug_last_iss1_pc_lo(debug_last_iss1_pc_lo),
    .debug_branch_pending_any(debug_branch_pending_any),
    .debug_br_found_t0(debug_br_found_t0),
    .debug_branch_in_flight_t0(debug_branch_in_flight_t0),
    .debug_oldest_br_ready_t0(debug_oldest_br_ready_t0),
    .debug_oldest_br_just_woke_t0(debug_oldest_br_just_woke_t0),
    .debug_oldest_br_qj_t0(debug_oldest_br_qj_t0),
    .debug_oldest_br_qk_t0(debug_oldest_br_qk_t0),
    .debug_slot1_flags(debug_slot1_flags),
    .debug_slot1_pc_lo(debug_slot1_pc_lo),
    .debug_slot1_qj(debug_slot1_qj),
    .debug_slot1_qk(debug_slot1_qk),
    .debug_tag2_flags(debug_tag2_flags),
    .debug_reg_x12_tag_t0(debug_reg_x12_tag_t0),
    .debug_slot1_issue_flags(debug_slot1_issue_flags),
    .debug_sel0_idx(debug_sel0_idx),
    .debug_slot1_fu(debug_slot1_fu),
    .debug_branch_issue_count(debug_branch_issue_count),
    .debug_branch_complete_count(debug_branch_complete_count)
);

uart_rx_monitor #(
    .CLK_DIV(1736)
) u_core_uart_monitor (
    .clk        (sys_clk_200m         ),
    .rst_n      (core_rst_n           ),
    .rx         (core_uart_tx         ),
    .frame_seen (core_uart_frame_seen ),
    .frame_count(core_uart_frame_count),
    .frame_count_rolling(core_uart_frame_count_rolling),
    .byte_valid (core_uart_byte_valid ),
    .byte_data  (core_uart_byte       )
);

uart_tx #(
    .CLK_DIV(1736)
) u_bridge_uart_tx (
    .clk      (sys_clk_200m    ),
    .rst_n    (core_rst_n      ),
    .tx_start (bridge_tx_start ),
    .tx_data  (bridge_tx_data  ),
    .tx       (bridged_uart_tx ),
    .busy     (bridge_uart_busy)
);

uart_rx_monitor #(
    .CLK_DIV(1736)
) u_bridge_uart_monitor (
    .clk        (sys_clk_200m           ),
    .rst_n      (core_rst_n             ),
    .rx         (bridged_uart_tx        ),
    .frame_seen (bridge_uart_frame_seen ),
    .frame_count(bridge_uart_frame_count),
    .frame_count_rolling(bridge_uart_frame_count_rolling)
);

uart_rx_monitor #(
    .CLK_DIV(1736)
) u_status_uart_monitor (
    .clk        (sys_clk_200m           ),
    .rst_n      (core_rst_n             ),
    .rx         (status_uart_tx         ),
    .frame_seen (                       ),
    .frame_count(status_uart_frame_count)
);

uart_status_beacon u_uart_status_beacon (
    .clk         (sys_clk_200m            ),
    .rst_n       (core_rst_n              ),
    .core_ready  (core_ready              ),
    .retire_seen (core_retire_seen        ),
    .tube_pass   (tube_status == 8'h04    ),
    .core_uart_seen(core_uart_seen        ),
    .core_uart_frame_seen(core_uart_frame_seen),
    .core_uart_frame_count_rolling(core_uart_frame_count_rolling),
    .bridge_uart_frame_count_rolling(bridge_uart_frame_count_rolling),
    .debug_uart_status_load_count(debug_uart_status_load_count),
    .debug_uart_tx_store_count(debug_uart_tx_store_count),
    .debug_uart_flags({debug_uart_status_busy, debug_uart_busy, debug_uart_pending_valid, 1'b0}),
    .debug_last_iss0_pc_lo(debug_last_iss0_pc_lo),
    .debug_last_iss1_pc_lo(debug_last_iss1_pc_lo),
    .debug_branch_pending_any(debug_branch_pending_any),
    .debug_br_found_t0(debug_br_found_t0),
    .debug_branch_in_flight_t0(debug_branch_in_flight_t0),
    .debug_oldest_br_ready_t0(debug_oldest_br_ready_t0),
    .debug_oldest_br_just_woke_t0(debug_oldest_br_just_woke_t0),
    .debug_oldest_br_qj_t0(debug_oldest_br_qj_t0),
    .debug_oldest_br_qk_t0(debug_oldest_br_qk_t0),
    .debug_slot1_flags(debug_slot1_flags),
    .debug_slot1_pc_lo(debug_slot1_pc_lo),
    .debug_slot1_qj(debug_slot1_qj),
    .debug_slot1_qk(debug_slot1_qk),
    .debug_tag2_flags(debug_tag2_flags),
    .debug_reg_x12_tag_t0(debug_reg_x12_tag_t0),
    .debug_slot1_issue_flags(debug_slot1_issue_flags),
    .debug_sel0_idx(debug_sel0_idx),
    .debug_slot1_fu(debug_slot1_fu),
    .debug_branch_issue_count(debug_branch_issue_count),
    .debug_branch_complete_count(debug_branch_complete_count),
    .tx          (status_uart_tx          )
);

assign uart_tx = status_uart_tx;

reg [24:0] led_cnt;
reg        led_blink;
reg [24:0] uart_led_hold_cnt;
reg        uart_led_visible;
reg [1:0]  uart_tx_sync;
wire       uart_tx_edge = uart_tx_sync[1] ^ uart_tx_sync[0];

always @(posedge sys_clk_200m or negedge core_rst_n) begin
    if (!core_rst_n) begin
        led_cnt   <= 25'd0;
        led_blink <= 1'b0;
    end else if (led_cnt == 25'd19_999_999) begin
        led_cnt   <= 25'd0;
        led_blink <= ~led_blink;
    end else begin
        led_cnt <= led_cnt + 25'd1;
    end
end

always @(posedge sys_clk_200m or negedge core_rst_n) begin
    if (!core_rst_n) begin
        bridge_tx_start      <= 1'b0;
        bridge_tx_data       <= 8'd0;
        bridge_pending_valid <= 1'b0;
        bridge_pending_byte  <= 8'd0;
    end else begin
        bridge_tx_start <= 1'b0;

        if (!bridge_uart_busy && bridge_pending_valid) begin
            bridge_tx_data       <= bridge_pending_byte;
            bridge_tx_start      <= 1'b1;
            bridge_pending_valid <= 1'b0;
            if (core_uart_byte_valid) begin
                bridge_pending_byte  <= core_uart_byte;
                bridge_pending_valid <= 1'b1;
            end
        end else if (core_uart_byte_valid) begin
            if (!bridge_uart_busy) begin
                bridge_tx_data  <= core_uart_byte;
                bridge_tx_start <= 1'b1;
            end else if (!bridge_pending_valid) begin
                bridge_pending_byte  <= core_uart_byte;
                bridge_pending_valid <= 1'b1;
            end
        end
    end
end

always @(posedge sys_clk_200m or negedge core_rst_n) begin
    if (!core_rst_n) begin
        core_uart_sync     <= 2'b11;
        core_uart_seen     <= 1'b0;
        uart_tx_sync      <= 2'b11;
        uart_led_hold_cnt <= 25'd0;
        uart_led_visible  <= 1'b0;
    end else begin
        core_uart_sync <= {core_uart_sync[0], core_uart_tx};
        if (core_uart_edge) begin
            core_uart_seen <= 1'b1;
        end
        uart_tx_sync <= {uart_tx_sync[0], status_uart_tx};
        if (uart_tx_edge) begin
            uart_led_hold_cnt <= 25'd19_999_999;
            uart_led_visible  <= 1'b1;
        end else if (uart_led_hold_cnt != 25'd0) begin
            uart_led_hold_cnt <= uart_led_hold_cnt - 25'd1;
            uart_led_visible  <= 1'b1;
        end else begin
            uart_led_visible  <= 1'b0;
        end
    end
end

assign led[0] = ~led_blink;
assign led[1] = ~core_ready;
assign led[2] = ~core_retire_seen;
assign led[3] = ~(tube_status == 8'h04);
assign led[4] = ~uart_led_visible;

wire _unused_uart_rx = uart_rx;
wire _unused_core_uart_tx = core_uart_tx;

endmodule
