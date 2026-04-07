# =============================================================================
# create_mig_ax7203.tcl — Generate MIG 7-Series IP for AX7203 DDR3
#
# DDR3: 2x MT41K256M16HA-125, 32-bit bus, 1GB total
# FPGA: XC7A200T-2FBG484I (BANK34/35)
# Clock: 200 MHz system clock (No Buffer — pre-buffered from IBUFGDS)
# PHY: 4:1 ratio, UI clock ~100 MHz, AXI data width 256 bits
#
# Usage:
#   vivado -mode batch -source fpga/ip/create_mig_ax7203.tcl
#   (or source from within create_project_ax7203.tcl)
# =============================================================================

# Resolve project directory
set script_dir [file dirname [file normalize [info script]]]
set proj_root  [file normalize "$script_dir/../.."]
set prj_file   [file normalize "$script_dir/mig_ax7203.prj"]

puts "INFO: Creating MIG 7-Series IP for AX7203 DDR3"
puts "INFO: PRJ file: $prj_file"

# Check that the PRJ file exists
if {![file exists $prj_file]} {
    puts "ERROR: MIG PRJ file not found: $prj_file"
    return -code error "MIG PRJ file missing"
}

# Create MIG IP (use version wildcard to adapt to Vivado version)
create_ip -name mig_7series -vendor xilinx.com -library ip \
          -module_name mig_7series_0

# Configure MIG with the PRJ file
set_property CONFIG.XML_INPUT_FILE $prj_file [get_ips mig_7series_0]

# Generate all targets (synthesis, simulation)
generate_target all [get_ips mig_7series_0]

# Create synthesis run for the IP
create_ip_run [get_ips mig_7series_0]

puts "INFO: MIG IP 'mig_7series_0' created and configured successfully"
puts "INFO: DDR3 config: MT41K256M16HA-125 x2, 32-bit bus, 400 MHz, AXI interface"
puts "INFO: UI clock: ~100 MHz, AXI data width: 256 bits"
