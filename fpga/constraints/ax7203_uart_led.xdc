################################################################################
# File: ax7203_uart_led.xdc
# Board: ALINX AX7203 (XC7A200T-2FBG484I)
# Scope: UART + LED constraints
#
# NOTE:
# - UART/LED pin assignments below are typical ALINX-style placeholders.
# - MUST verify against actual AX7203 schematic and board revision before use.
################################################################################

################################################################################
# 1) USB-UART (CP2102GM) pins
################################################################################

# Typical UART pin candidates (3.3V bank, often bank 15/16 on ALINX boards)
# TODO(verify): Confirm exact FPGA pins connected to CP2102GM TXD/RXD.
# FPGA TX (to PC RX)
set_property PACKAGE_PIN A16 [get_ports uart_tx]
set_property IOSTANDARD LVCMOS33 [get_ports uart_tx]

# FPGA RX (from PC TX)
set_property PACKAGE_PIN A15 [get_ports uart_rx]
set_property IOSTANDARD LVCMOS33 [get_ports uart_rx]

# Hold RX high when line is idle/floating.
set_property PULLUP true [get_ports uart_rx]

################################################################################
# 2) UART timing constraints (initial placeholder for bring-up)
################################################################################

# UART is asynchronous to sys_clk; define a virtual reference clock for I/O delay
# bookkeeping (115200 baud => bit period 8.680556 us = 8680.556 ns).
create_clock -name uart_line_clk -period 8680.556

# Conservative board-level placeholders; refine after schematic + SI review.
set_output_delay -clock [get_clocks uart_line_clk] -max 5.000 [get_ports uart_tx]
set_output_delay -clock [get_clocks uart_line_clk] -min -5.000 [get_ports uart_tx]

set_input_delay -clock [get_clocks uart_line_clk] -max 5.000 [get_ports uart_rx]
set_input_delay -clock [get_clocks uart_line_clk] -min 0.000 [get_ports uart_rx]

# UART virtual timing domain is asynchronous to FPGA system clock domain.
set_clock_groups -asynchronous \
  -group [get_clocks sys_clk] \
  -group [get_clocks uart_line_clk]

################################################################################
# 3) User LEDs (5 total)
################################################################################

# Typical ALINX LED pin candidates on 3.3V I/O bank.
# TODO(verify): Confirm LED0..LED4 physical mapping and active polarity.
set_property PACKAGE_PIN G14 [get_ports {led[0]}]
set_property PACKAGE_PIN F14 [get_ports {led[1]}]
set_property PACKAGE_PIN E14 [get_ports {led[2]}]
set_property PACKAGE_PIN D14 [get_ports {led[3]}]
set_property PACKAGE_PIN C14 [get_ports {led[4]}]

set_property IOSTANDARD LVCMOS33 [get_ports {led[0]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[1]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[2]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[4]}]

set_property DRIVE 8 [get_ports {led[0]}]
set_property DRIVE 8 [get_ports {led[1]}]
set_property DRIVE 8 [get_ports {led[2]}]
set_property DRIVE 8 [get_ports {led[3]}]
set_property DRIVE 8 [get_ports {led[4]}]

set_property SLEW SLOW [get_ports {led[0]}]
set_property SLEW SLOW [get_ports {led[1]}]
set_property SLEW SLOW [get_ports {led[2]}]
set_property SLEW SLOW [get_ports {led[3]}]
set_property SLEW SLOW [get_ports {led[4]}]

################################################################################
# 4) Debug visibility recommendations (optional, commented)
################################################################################

# Uncomment and adapt for debug builds.
# set_property MARK_DEBUG TRUE [get_nets -of_objects [get_ports uart_txd]]
# set_property MARK_DEBUG TRUE [get_nets -of_objects [get_ports uart_rxd]]
# set_property MARK_DEBUG TRUE [get_nets -of_objects [get_ports {led[0]}]]
