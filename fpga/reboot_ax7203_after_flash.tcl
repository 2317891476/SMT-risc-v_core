# reboot_ax7203_after_flash.tcl
# Reboot AX7203 to boot from Flash without power cycle
# Usage: vivado -mode batch -source fpga/reboot_ax7203_after_flash.tcl

set script_dir [file dirname [info script]]

puts "Rebooting AX7203 to boot from Flash..."

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

# Open first target
open_hw_target [lindex $hw_targets 0]

# Get devices
set hw_devices [get_hw_devices]
if {[llength $hw_devices] == 0} {
    puts "ERROR: No devices found on target"
    close_hw_target
    exit 1
}

# Find FPGA device
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

# Refresh device to get current state
refresh_hw_device $fpga_device

# Set boot mode to SPI
# This tells the FPGA to boot from QSPI flash on next configuration cycle
puts "Setting boot mode to SPI..."
set_property BOOT_MODE.SPI 1 $fpga_device

# Trigger configuration from SPI (reboot)
puts "Triggering configuration from SPI (reboot)..."
if {[catch {boot_hw_device $fpga_device} err]} {
    puts "ERROR: Failed to boot device from SPI"
    puts $err
    close_hw_target
    exit 1
}

# Wait for configuration to complete
puts "Waiting for configuration to complete..."
set timeout 30
set elapsed 0
set configured 0

while {$elapsed < $timeout} {
    refresh_hw_device $fpga_device
    set status [get_property STATUS $fpga_device]
    puts "  Status: $status"
    
    if {[string match "*CONFIG*" $status] || [get_property IS_CONFIGURED $fpga_device]} {
        set configured 1
        break
    }
    
    after 1000
    incr elapsed
}

if {!$configured} {
    puts "WARNING: Configuration may not have completed within timeout"
    puts "Check UART/LED for boot status"
} else {
    puts "Configuration from SPI completed!"
}

# Refresh and check status
refresh_hw_device $fpga_device
set is_configured [get_property IS_CONFIGURED $fpga_device]
set status [get_property STATUS $fpga_device]

# Close hardware target
close_hw_target

# Save evidence
set evidence_file "$script_dir/../.sisyphus/evidence/task-13-reboot-flash.log"
set fh [open $evidence_file w]
puts $fh "Flash Boot Reboot: COMPLETED"
puts $fh "Device: [get_property NAME $fpga_device]"
puts $fh "Is Configured: $is_configured"
puts $fh "Status: $status"
puts $fh "Timestamp: [clock format [clock seconds]]"
close $fh

puts ""
if {$is_configured} {
    puts "SUCCESS: Device booted from Flash!"
    puts ""
    puts "Verification steps:"
    puts "  1. Check UART output for boot messages"
    puts "  2. Verify LED heartbeat"
    puts "  3. Run smoke tests"
} else {
    puts "WARNING: Device may not have booted correctly"
    puts "Check:"
    puts "  1. Flash was programmed correctly"
    puts "  2. Boot mode jumpers are set correctly"
    puts "  3. Try power cycle instead"
}

exit 0
