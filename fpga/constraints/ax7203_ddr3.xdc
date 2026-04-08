# =============================================================================
# ax7203_ddr3.xdc
# DDR3 SDRAM constraints for ALINX AX7203 (XC7A200T-2FBG484I)
# DDR3: 2x MT41K256M16HA-125, 32-bit bus, BANK34 + BANK35
#
# NOTE: Pin-level assignments (DQ, DQS, ADDR, CTRL) are handled by the MIG IP
# core through the mig_ax7203.prj XML file.  This XDC only provides timing
# constraints that the MIG core does not generate automatically.
# =============================================================================

# ─────────────────────────────────────────────────────────────────────────────
# 1. CDC false paths between core clock (~10 MHz) and MIG ui_clk (~100 MHz)
# ─────────────────────────────────────────────────────────────────────────────
# The ddr3_mem_port bridge uses ASYNC_REG synchronizers for the toggle-flag
# CDC.  Vivado must not attempt single-cycle timing closure across these.

set_false_path -from [get_cells -hierarchical -filter {NAME =~ *u_ddr3_mem_port/req_flag_core_reg*}] \
               -to   [get_cells -hierarchical -filter {NAME =~ *u_ddr3_mem_port/req_flag_ui_sync_reg*}]

set_false_path -from [get_cells -hierarchical -filter {NAME =~ *u_ddr3_mem_port/resp_flag_ui_reg*}] \
               -to   [get_cells -hierarchical -filter {NAME =~ *u_ddr3_mem_port/resp_flag_core_sync_reg*}]

# Data transfer registers are stable by the time the flag arrives (held
# constant until ack toggles back), so mark them as false paths too.
set_false_path -from [get_cells -hierarchical -filter {NAME =~ *u_ddr3_mem_port/req_addr_r_reg*}]  \
               -to   [get_cells -hierarchical -filter {NAME =~ *u_ddr3_mem_port/ui_addr_reg*}]
set_false_path -from [get_cells -hierarchical -filter {NAME =~ *u_ddr3_mem_port/req_write_r_reg*}] \
               -to   [get_cells -hierarchical -filter {NAME =~ *u_ddr3_mem_port/ui_write_reg*}]
set_false_path -from [get_cells -hierarchical -filter {NAME =~ *u_ddr3_mem_port/req_wdata_r_reg*}] \
               -to   [get_cells -hierarchical -filter {NAME =~ *u_ddr3_mem_port/ui_wdata_reg*}]
set_false_path -from [get_cells -hierarchical -filter {NAME =~ *u_ddr3_mem_port/req_wen_r_reg*}]   \
               -to   [get_cells -hierarchical -filter {NAME =~ *u_ddr3_mem_port/ui_wen_reg*}]

set_false_path -from [get_cells -hierarchical -filter {NAME =~ *u_ddr3_mem_port/resp_data_ui_reg*}] \
               -to   [get_cells -hierarchical -filter {NAME =~ *u_ddr3_mem_port/resp_data_r_reg*}]

# Additional CDC paths uncovered by frequency sweep (core_clk ↔ ui_clk):
# req_write_r feeds ui_state FSM via combinational decode in the ui_clk domain.
set_false_path -from [get_cells -hierarchical -filter {NAME =~ *u_ddr3_mem_port/req_write_r_reg*}] \
               -to   [get_cells -hierarchical -filter {NAME =~ *u_ddr3_mem_port/ui_state_reg*}]
set_false_path -from [get_cells -hierarchical -filter {NAME =~ *u_ddr3_mem_port/req_addr_r_reg*}]  \
               -to   [get_cells -hierarchical -filter {NAME =~ *u_ddr3_mem_port/ui_state_reg*}]
set_false_path -from [get_cells -hierarchical -filter {NAME =~ *u_ddr3_mem_port/req_wen_r_reg*}]   \
               -to   [get_cells -hierarchical -filter {NAME =~ *u_ddr3_mem_port/ui_state_reg*}]

# resp_data_ui crosses from ui_clk domain to core domain (into LSU shell).
# Data is stable by the time resp_flag synchronizer propagates.
set_false_path -from [get_cells -hierarchical -filter {NAME =~ *u_ddr3_mem_port/resp_data_ui_reg*}] \
               -to   [get_cells -hierarchical -filter {NAME =~ *u_lsu_shell/raw_mem_rdata_reg*}]

# ─────────────────────────────────────────────────────────────────────────────
# 2. MIG init_calib_complete is quasi-static (changes once after power-up)
# ─────────────────────────────────────────────────────────────────────────────
set_false_path -from [get_cells -hierarchical -filter {NAME =~ *init_calib_complete_reg*}]

# ─────────────────────────────────────────────────────────────────────────────
# 3. Bank 34 voltage override for led[0] (W5)
# ─────────────────────────────────────────────────────────────────────────────
# With DDR3 enabled, Bank 34 VCCO = 1.5V (SSTL15).  led[0] at W5 (Bank 34)
# was originally LVCMOS33 which conflicts.  Override to LVCMOS15 for DDR3 mode.
# LED will be dimmer at 1.5V drive but the IO bank voltage conflict is resolved.
set_property IOSTANDARD LVCMOS15 [get_ports {led[0]}]

# sys_rst_n at T6 is also in Bank 34 — override from LVCMOS33 to LVCMOS15.
# The reset push-button pull-up is connected to VCCO, which is 1.5V in DDR3 mode.
set_property IOSTANDARD LVCMOS15 [get_ports sys_rst_n]
