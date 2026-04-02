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
# 2) UART timing constraints
################################################################################

# The CP2102 UART link is asynchronous to the FPGA system clock. For this
# bring-up design we intentionally exclude direct UART pad timing from closure
# so the core timing report focuses on synchronous on-chip paths.
set_false_path -to [get_ports uart_tx]
set_false_path -from [get_ports uart_rx]

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
