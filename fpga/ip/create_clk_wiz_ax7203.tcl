# AX7203 clock wizard IP generation script
#
# Usage (standalone):
#   vivado -mode batch -source fpga/ip/create_clk_wiz_ax7203.tcl
#
# Usage (from existing project flow):
#   source fpga/ip/create_clk_wiz_ax7203.tcl
#
# Generates:
#   - clk_wiz_0 (MMCM based)
#   - Input clock: 200.000 MHz
#   - Output clock: 50.000 MHz (single output for initial bring-up)

# Sanity check: this script must run inside Vivado Tcl.
if {[llength [info commands create_ip]] == 0} {
  puts "ERROR: Vivado Tcl commands are not available."
  return -code error
}

set clk_script_dir [file dirname [file normalize [info script]]]
set clk_ip_name "clk_wiz_0"
set clk_primary_part "xc7a200t-2fbg484i"
set clk_fallback_parts [list "xc7a200tfbg484-2" "xc7a200tfbg484-2L"]

# Determine target part
set clk_part_name ""
if {[llength [get_parts -quiet $clk_primary_part]] > 0} {
  set clk_part_name $clk_primary_part
} else {
  foreach p $clk_fallback_parts {
    if {[llength [get_parts -quiet $p]] > 0} {
      set clk_part_name $p
      puts "WARNING: Requested part '$clk_primary_part' is unavailable in this Vivado install."
      puts "WARNING: Falling back to compatible part '$clk_part_name'."
      break
    }
  }
}

if {$clk_part_name eq ""} {
  puts "ERROR: None of the expected AX7203-compatible parts are available."
  puts "ERROR: Tried: $clk_primary_part, [join $clk_fallback_parts {, }]"
  return -code error
}

# Check if we're being sourced from an existing project
set clk_cur_proj [current_project -quiet]
set clk_created_local_project 0
set clk_proj_dir ""

if {$clk_cur_proj eq ""} {
  # No project open - create standalone project for IP generation
  set clk_proj_dir [file join $clk_script_dir "clk_wiz_0_prj"]
  file mkdir $clk_proj_dir
  puts "INFO: No open project detected. Creating standalone IP project."
  puts "INFO: Generating $clk_ip_name for AX7203"
  puts "INFO: Project directory: $clk_proj_dir"
  puts "INFO: Using part: $clk_part_name"
  create_project $clk_ip_name $clk_proj_dir -force -part $clk_part_name
  set clk_created_local_project 1
} else {
  # Project already open - add IP to current project
  puts "INFO: Adding $clk_ip_name to current project: $clk_cur_proj"
  puts "INFO: Using part: $clk_part_name"
}

# Create Clocking Wizard IP.
create_ip -name clk_wiz -vendor xilinx.com -library ip -module_name $clk_ip_name

# MMCM configuration for AX7203 bring-up clocking:
#   Fin  = 200.000 MHz (differential oscillator source)
#   Fvco = Fin / DIVCLK * CLKFBOUT_MULT = 200 / 1 * 5 = 1000 MHz
#   Fout = Fvco / CLKOUT0_DIVIDE = 1000 / 20 = 50 MHz
#
# Keep only one output clock for initial integration simplicity.
set_property -dict [list \
  CONFIG.PRIMITIVE {MMCM} \
  CONFIG.PRIM_SOURCE {Differential_clock_capable_pin} \
  CONFIG.PRIM_IN_FREQ {200.000} \
  CONFIG.CLKIN1_JITTER_PS {50.0} \
  CONFIG.NUM_OUT_CLKS {1} \
  CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {50.000} \
  CONFIG.CLKOUT1_REQUESTED_PHASE {0.000} \
  CONFIG.CLKOUT1_REQUESTED_DUTY_CYCLE {50.000} \
  CONFIG.USE_RESET {true} \
  CONFIG.RESET_TYPE {ACTIVE_HIGH} \
  CONFIG.USE_LOCKED {true} \
  CONFIG.MMCM_DIVCLK_DIVIDE {1} \
  CONFIG.MMCM_CLKFBOUT_MULT_F {5.000} \
  CONFIG.MMCM_CLKOUT0_DIVIDE_F {20.000} \
] [get_ips $clk_ip_name]

# Get the XCI path
set clk_xci_path [get_files -quiet */$clk_ip_name.xci]
if {[llength $clk_xci_path] == 0} {
  puts "ERROR: Failed to locate generated XCI for $clk_ip_name"
  return -code error
}

# Generate output products and templates.
generate_target {instantiation_template} $clk_xci_path
generate_target all $clk_xci_path
export_ip_user_files -of_objects $clk_xci_path -no_script -sync -force

puts "INFO: Clock wizard IP generation complete."
puts "INFO: XCI: $clk_xci_path"

if {$clk_created_local_project} {
  close_project
}

# Note: Do NOT call exit - let the parent script control flow
