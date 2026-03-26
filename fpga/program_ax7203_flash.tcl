# program_ax7203_flash.tcl
# Program QSPI Flash on AX7203
# Usage: vivado -mode batch -source fpga/program_ax7203_flash.tcl

set script_dir [file dirname [info script]]
set project_dir "$script_dir/../build/ax7203"
set project_name "adam_riscv_ax7203"

# Parse arguments
set target_part "xc7a200t-2fbg484i"
if {[info exists ::env(TARGET_PART)]} {
    set target_part $::env(TARGET_PART)
}

set cfgmem_file "$project_dir/cfgmem/${project_name}_${target_part}_cfg.mcs"

# Check if cfgmem file exists
if {![file exists $cfgmem_file]} {
    puts "ERROR: Configuration memory file not found: $cfgmem_file"
    puts "Generate first: vivado -mode batch -source fpga/write_ax7203_cfgmem.tcl"
    exit 1
}

puts "Programming QSPI Flash on AX7203..."
puts "Configuration file: $cfgmem_file"

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

# Find FPGA device (needed to get to the flash)
set fpga_device ""
foreach device $hw_devices {
    set device_name [get_property NAME $device]
    if {[string match "*xc7a200t*" $device_name]} {
        set fpga_device $device
        break
    }
}

if {$fpga_device == ""} {
    puts "ERROR: XC7A200T device not found"
    close_hw_target
    exit 1
}

puts "Found FPGA: [get_property NAME $fpga_device]"

# Create or get hw_cfgmem object
# Note: The flash is typically associated with the FPGA device
set flash_device [lindex [get_hw_devices -filter {NAME =~ "*flash*"}] 0]

if {$flash_device == ""} {
    # Try to create cfgmem object for the flash
    puts "Creating cfgmem object for flash..."
    create_hw_cfgmem -hw_device $fpga_device [lindex [get_cfgmem_parts {s25fl256s* || n25q256* || mt25ql256* || w25q256*}] 0]
    set flash_device [get_hw_cfgmem -of $fpga_device]
}

if {$flash_device == ""} {
    puts "ERROR: Could not access flash device"
    puts "Make sure:"
    puts "  1. JTAG cable is connected"
    puts "  2. Board is powered on"
    puts "  3. Flash is properly seated"
    close_hw_target
    exit 1
}

puts "Flash device: [get_property NAME $flash_device]"

# Set programming file
set_property PROGRAM.FILES [list $cfgmem_file] $flash_device
set_property PROGRAM.PRM_FILES [list ${cfgmem_file}.prm] $flash_device
set_property PROGRAM.BLANK_CHECK 0 $flash_device
set_property PROGRAM.ERASE 1 $flash_device
set_property PROGRAM.CFG_PROGRAM 1 $flash_device
set_property PROGRAM.VERIFY 1 $flash_device

# Program flash
puts "Programming flash (this may take 1-2 minutes)..."
if {[catch {program_hw_cfgmem $flash_device} err]} {
    puts "ERROR: Flash programming failed"
    puts $err
    close_hw_target
    exit 1
}

puts "Flash programming completed successfully!"

# Close hardware target
close_hw_target

# Save evidence
set evidence_file "$script_dir/../.sisyphus/evidence/task-13-flash-program.log"
set fh [open $evidence_file w]
puts $fh "Flash Programming: SUCCESS"
puts $fh "Configuration file: $cfgmem_file"
puts $fh "Flash device: [get_property NAME $flash_device]"
puts $fh "Timestamp: [clock format [clock seconds]]"
close $fh

puts ""
puts "Next steps:"
puts "  1. Disconnect JTAG or power cycle"
puts "  2. Board should boot from Flash automatically"
puts "  3. Check UART output for boot messages"
puts ""
puts "To verify Flash boot without power cycle:"
puts "  vivado -mode batch -source fpga/reboot_ax7203_after_flash.tcl"

exit 0
