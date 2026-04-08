################################################################################
# File: ax7203_base.xdc
# Board: ALINX AX7203 (XC7A200T-2FBG484I)
# Scope: Base constraints (clock, reset, baseline timing)
#
# NOTE:
# - SYS_CLK_P/N pins are from board manifest and should be authoritative.
# - Reset pin below uses a typical ALINX assignment and MUST be verified against
#   the exact AX7203 schematic/revision before production signoff.
################################################################################

################################################################################
# 1) 200 MHz differential system clock (SiT9102)
################################################################################

# Configuration bank voltage (AX7203 board resources are 3.3V on the relevant
# configuration rail per board/resource docs).
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]

# Differential clock input pins (from fpga/board_manifest_ax7203.md)
set_property PACKAGE_PIN R4 [get_ports sys_clk_p]
set_property PACKAGE_PIN T4 [get_ports sys_clk_n]

# Bank 34 differential I/O standard (HR bank). DIFF_SSTL15 requested.
set_property IOSTANDARD DIFF_SSTL15 [get_ports sys_clk_p]
set_property IOSTANDARD DIFF_SSTL15 [get_ports sys_clk_n]

# Primary system clock definition: 200 MHz => 5.000 ns period
# Use the P-side port as the timing reference.
create_clock -name sys_clk -period 5.000 [get_ports sys_clk_p]

################################################################################
# 2) Reset input (active-low push button)
################################################################################

# Official AX7203 reset pin from resource.md section 8.2
# RESET_N = T6 (active-low push button on core board)
set_property PACKAGE_PIN T6 [get_ports sys_rst_n]
set_property IOSTANDARD LVCMOS33 [get_ports sys_rst_n]
set_property PULLUP true [get_ports sys_rst_n]

################################################################################
# 3) Baseline timing exceptions (justified)
################################################################################

# Reset button is asynchronous to sys_clk; exclude direct reset path timing.
set_false_path -from [get_ports sys_rst_n]

# POR reset synchronizer: por_rst_n (sys_clk domain) feeds the core clock
# domain rst synchronizer via ASYNC_REG chain.  This CDC path is safe by
# construction (reset de-asserts cleanly after multiple sys_clk cycles).
set_false_path -from [get_cells -hierarchical -filter {NAME =~ *por_rst_n_reg*}] \
               -to   [get_cells -hierarchical -filter {NAME =~ *u_syn_rst/rst_nr*_reg*}]

# If extra clocks are added later (e.g., PLL/MMCM outputs or UART virtual clock),
# place asynchronous clock-group constraints in the corresponding XDC.
# Example:
# set_clock_groups -asynchronous \
#   -group [get_clocks sys_clk] \
#   -group [get_clocks other_async_clk]

################################################################################
# 4) Debug visibility recommendations (optional, commented)
################################################################################

# Uncomment and adapt instance/net names after synthesis if needed.
# set_property MARK_DEBUG TRUE [get_nets -of_objects [get_ports sys_clk_p]]
# set_property MARK_DEBUG TRUE [get_nets -of_objects [get_ports rst_n]]
