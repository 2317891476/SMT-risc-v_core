open_hw_manager
set_param labtools.enable_cs_server false
connect_hw_server -url TCP:localhost:3121

set targets [get_hw_targets *]
puts "HW targets: $targets"

if {[llength $targets] == 0} {
    puts "ERROR: No hardware target found. JTAG cable or driver may be missing."
    exit 1
}

current_hw_target [lindex $targets 0]
open_hw_target

set devices [get_hw_devices]
puts "HW devices: $devices"

if {[llength $devices] == 0} {
    puts "ERROR: Hardware target opened, but no FPGA device detected on JTAG chain."
    exit 2
}

puts "SUCCESS: JTAG connection is alive and FPGA device(s) are visible."
exit 0
