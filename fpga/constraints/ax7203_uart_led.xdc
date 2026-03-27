################################################################################
# File: ax7203_uart_led.xdc
# Board: ALINX AX7203 (XC7A200T-2FBG484I)
# Scope: UART and LED constraints
# Reference: fpga/resource.md (official ALINX documentation)
################################################################################

################################################################################
# 1) USB-UART (CP2102GM) pins
################################################################################

# AX7203 USB UART pins from schematic
# UART1_TXD = N15, UART1_RXD = P20
# FPGA TX (to PC RX via CP2102)
set_property PACKAGE_PIN N15 [get_ports uart_tx]
set_property IOSTANDARD LVCMOS33 [get_ports uart_tx]

# FPGA RX (from PC TX via CP2102)
set_property PACKAGE_PIN P20 [get_ports uart_rx]
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
# 3) Debug visibility recommendations (optional, commented)
################################################################################

################################################################################
# 3) LED pins (from resource.md)
################################################################################

# Core board LED1 (active-low, high=off, low=on)
set_property PACKAGE_PIN W5 [get_ports {led[0]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[0]}]

# Extension board LEDs (active-low)
set_property PACKAGE_PIN B13 [get_ports {led[1]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[1]}]

set_property PACKAGE_PIN C13 [get_ports {led[2]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[2]}]

set_property PACKAGE_PIN D14 [get_ports {led[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[3]}]

set_property PACKAGE_PIN D15 [get_ports {led[4]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[4]}]

################################################################################
# 4) Debug visibility recommendations (optional, commented)
################################################################################

# Uncomment and adapt for debug builds.
# set_property MARK_DEBUG TRUE [get_nets -of_objects [get_ports uart_tx]]
# set_property MARK_DEBUG TRUE [get_nets -of_objects [get_ports uart_rx]]
