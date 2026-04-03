`ifndef FPGA_MODE
    `define FPGA_MODE 1
`endif

module adam_riscv_ax7203_issue_probe_top (
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
        por_cnt <= por_cnt + 16'd1;
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
wire       core_ready;
wire       core_retire_seen;
wire [7:0] debug_last_iss0_pc_lo;
wire [7:0] debug_last_iss1_pc_lo;
wire       debug_branch_pending_any;
wire       debug_br_found_t0;
wire       debug_branch_in_flight_t0;
wire [3:0] debug_oldest_br_qj_t0;
wire [7:0] debug_oldest_br_seq_lo_t0;
wire [15:0] debug_rs_flags_flat;
wire [31:0] debug_rs_pc_lo_flat;
wire [15:0] debug_rs_fu_flat;
wire [15:0] debug_rs_qj_flat;
wire [15:0] debug_rs_qk_flat;
wire [31:0] debug_rs_seq_lo_flat;
wire       probe_uart_tx;

(* KEEP_HIERARCHY = "TRUE" *)
adam_riscv u_adam_riscv (
    .sys_clk(sys_clk_200m),
    .sys_rstn(core_rst_n),
    .uart_rx(uart_rx),
    .ext_irq_src(1'b0),
    .led(core_led),
    .tube_status(tube_status),
    .uart_tx(),
    .debug_core_ready(core_ready),
    .debug_retire_seen(core_retire_seen),
    .debug_last_iss0_pc_lo(debug_last_iss0_pc_lo),
    .debug_last_iss1_pc_lo(debug_last_iss1_pc_lo),
    .debug_branch_pending_any(debug_branch_pending_any),
    .debug_br_found_t0(debug_br_found_t0),
    .debug_branch_in_flight_t0(debug_branch_in_flight_t0),
    .debug_oldest_br_qj_t0(debug_oldest_br_qj_t0),
    .debug_oldest_br_seq_lo_t0(debug_oldest_br_seq_lo_t0),
    .debug_rs_flags_flat(debug_rs_flags_flat),
    .debug_rs_pc_lo_flat(debug_rs_pc_lo_flat),
    .debug_rs_fu_flat(debug_rs_fu_flat),
    .debug_rs_qj_flat(debug_rs_qj_flat),
    .debug_rs_qk_flat(debug_rs_qk_flat),
    .debug_rs_seq_lo_flat(debug_rs_seq_lo_flat)
);

uart_issue_probe_beacon u_probe_beacon (
    .clk(sys_clk_200m),
    .rst_n(core_rst_n),
    .core_ready(core_ready),
    .retire_seen(core_retire_seen),
    .tube_pass(tube_status == 8'h04),
    .last_iss0_pc_lo(debug_last_iss0_pc_lo),
    .last_iss1_pc_lo(debug_last_iss1_pc_lo),
    .branch_pending(debug_branch_pending_any),
    .br_found_t0(debug_br_found_t0),
    .branch_in_flight_t0(debug_branch_in_flight_t0),
    .oldest_br_qj_t0(debug_oldest_br_qj_t0),
    .oldest_br_seq_lo_t0(debug_oldest_br_seq_lo_t0),
    .rs_flags_flat(debug_rs_flags_flat),
    .rs_pc_lo_flat(debug_rs_pc_lo_flat),
    .rs_fu_flat(debug_rs_fu_flat),
    .rs_qj_flat(debug_rs_qj_flat),
    .rs_qk_flat(debug_rs_qk_flat),
    .rs_seq_lo_flat(debug_rs_seq_lo_flat),
    .tx(probe_uart_tx)
);

assign uart_tx = probe_uart_tx;

reg [24:0] led_cnt;
reg led_blink;
reg [24:0] uart_led_hold_cnt;
reg uart_led_visible;
reg [1:0] uart_tx_sync;
wire uart_tx_edge = uart_tx_sync[1] ^ uart_tx_sync[0];

always @(posedge sys_clk_200m or negedge core_rst_n) begin
    if (!core_rst_n) begin
        led_cnt <= 25'd0;
        led_blink <= 1'b0;
    end else if (led_cnt == 25'd19_999_999) begin
        led_cnt <= 25'd0;
        led_blink <= ~led_blink;
    end else begin
        led_cnt <= led_cnt + 25'd1;
    end
end

always @(posedge sys_clk_200m or negedge core_rst_n) begin
    if (!core_rst_n) begin
        uart_tx_sync <= 2'b11;
        uart_led_hold_cnt <= 25'd0;
        uart_led_visible <= 1'b0;
    end else begin
        uart_tx_sync <= {uart_tx_sync[0], uart_tx};
        if (uart_tx_edge) begin
            uart_led_hold_cnt <= 25'd4_000_000;
            uart_led_visible <= 1'b1;
        end else if (uart_led_hold_cnt != 25'd0) begin
            uart_led_hold_cnt <= uart_led_hold_cnt - 25'd1;
            uart_led_visible <= 1'b1;
        end else begin
            uart_led_visible <= 1'b0;
        end
    end
end

assign led[0] = ~led_blink;
assign led[1] = ~core_ready;
assign led[2] = ~core_retire_seen;
assign led[3] = ~(tube_status == 8'h04);
assign led[4] = ~uart_led_visible;

endmodule
