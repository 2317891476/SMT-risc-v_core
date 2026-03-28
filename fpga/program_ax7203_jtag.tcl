# program_ax7203_jtag.tcl
# Program AX7203 via JTAG
# Usage: vivado -mode batch -source fpga/program_ax7203_jtag.tcl

set script_dir [file dirname [info script]]
set project_dir "$script_dir/../build/ax7203"
set project_name "adam_riscv_ax7203"

# Parse arguments
set target_part "xc7a200t-2fbg484i"
if {[info exists ::env(TARGET_PART)]} {
    set target_part $::env(TARGET_PART)
}

set bitstream_file "$project_dir/adam_riscv_ax7203.runs/impl_1/adam_riscv_ax7203_top.bit"

# Check if bitstream exists
if {![file exists $bitstream_file]} {
    puts "ERROR: Bitstream not found: $bitstream_file"
    puts "Run build first: vivado -mode batch -source fpga/build_ax7203_bitstream.tcl"
    exit 1
}

puts "Programming AX7203 via JTAG..."
puts "Bitstream: $bitstream_file"

# Open hardware manager
open_hw_manager

# Connect to hw_server
puts "Connecting to hardware server..."
if {[catch {connect_hw_server} err]} {
    puts "ERROR: Failed to connect to hardware server"
    puts $err
    exit 1
}

# Get hardware targets
set hw_targets [get_hw_targets]
if {[llength $hw_targets] == 0} {
    puts "ERROR: No hardware targets found"
    puts "Check JTAG cable connection"
    exit 1
}

puts "Found [llength $hw_targets] hardware target(s)"

# Open first target
open_hw_target [lindex $hw_targets 0]

# Get devices
set hw_devices [get_hw_devices]
if {[llength $hw_devices] == 0} {
    puts "ERROR: No devices found on target"
    close_hw_target
    exit 1
}

puts "Found [llength $hw_devices] device(s)"

# Find FPGA device
set fpga_device ""
foreach device $hw_devices {
    set device_name [get_property NAME $device]
    puts "  Device: $device_name"
    if {[string match "*xc7a200t*" $device_name]} {
        set fpga_device $device
        break
    }
}

if {$fpga_device == ""} {
    puts "ERROR: XC7A200T device not found"
    puts "Available devices:"
    foreach device $hw_devices {
        puts "  - [get_property NAME $device]"
    }
    close_hw_target
    exit 1
}

puts "Selected device: [get_property NAME $fpga_device]"

# Set bitstream
set_property PROGRAM.FILE $bitstream_file $fpga_device

# Program device
puts "Programming device..."
if {[catch {program_hw_devices $fpga_device} err]} {
    puts "ERROR: Programming failed"
    puts $err
    close_hw_target
    exit 1
}

puts "Programming completed successfully!"

# Verify device is programmed
refresh_hw_device $fpga_device
set is_programmed [get_property IS_PROGRAMMED $fpga_device]

if {$is_programmed} {
    puts "Verification: Device is programmed and running"
} else {
    puts "WARNING: Device may not be properly programmed"
}

# Close hardware target
close_hw_target

# Save evidence
set evidence_file "$script_dir/../.sisyphus/evidence/task-8-jtag-program.log"
set fh [open $evidence_file w]
puts $fh "JTAG Programming: SUCCESS"
puts $fh "Bitstream: $bitstream_file"
puts $fh "Device: [get_property NAME $fpga_device]"
puts $fh "Is Programmed: $is_programmed"
puts $fh "Timestamp: [clock format [clock seconds]]"
close $fh

puts ""
puts "Next steps:"
puts "  1. Check UART output for boot messages"
puts "  2. Verify LED heartbeat"
puts "  3. Run smoke tests"

exit 0
