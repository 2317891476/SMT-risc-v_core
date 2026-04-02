# program_ax7203_jtag.tcl
# Program AX7203 via JTAG
# Usage: vivado -mode batch -source fpga/program_ax7203_jtag.tcl

set script_dir [file dirname [info script]]
source "$script_dir/flow_common.tcl"

set project_dir [file normalize [ax7203_env_or_default PROJECT_DIR "$script_dir/../build/ax7203"]]
set project_name "adam_riscv_ax7203"
set top_module [ax7203_env_or_default AX7203_TOP_MODULE "adam_riscv_ax7203_top"]

# Parse arguments
set target_part [ax7203_env_or_default TARGET_PART "xc7a200tfbg484-2"]
if {$top_module eq "adam_riscv_ax7203_top"} {
    set default_bitstream "$project_dir/${project_name}_${target_part}.bit"
    set build_id_file "$project_dir/${project_name}_bitstream_id.txt"
} else {
    set default_bitstream "$project_dir/${project_name}_${top_module}_${target_part}.bit"
    set build_id_file "$project_dir/${project_name}_${top_module}_bitstream_id.txt"
}
set bitstream_file [ax7203_env_or_default BITSTREAM_FILE $default_bitstream]
set expected_build_id ""

proc ax7203_normalize_hex {value} {
    set clean [string toupper $value]
    regsub -all {[^0-9A-F]} $clean {} clean
    regsub {^0+} $clean {} clean
    if {$clean eq ""} {
        return "0"
    }
    return $clean
}

# Check if bitstream exists
if {![file exists $bitstream_file]} {
    puts "ERROR: Bitstream not found: $bitstream_file"
    puts "Run build first: vivado -mode batch -source fpga/build_ax7203_bitstream.tcl"
    exit 1
}

puts "Programming AX7203 via JTAG..."
puts "Bitstream: $bitstream_file"
puts "Top module: $top_module"
if {![file exists $build_id_file]} {
    puts "ERROR: Build manifest not found: $build_id_file"
    puts "Run build first so the bitstream can be versioned and read back safely."
    exit 1
}
set build_id_fh [open $build_id_file r]
set build_id_text [read $build_id_fh]
close $build_id_fh
if {[regexp {BUILD_ID=(0x[0-9A-Fa-f]+)} $build_id_text -> expected_id]} {
    set expected_build_id $expected_id
    puts "Expected build ID: $expected_build_id"
} else {
    puts "ERROR: Failed to parse BUILD_ID from $build_id_file"
    exit 1
}

# Open hardware manager
open_hw_manager

# Board bring-up only needs JTAG configuration access. Disable cs_server so
# Vivado does not try to launch the ChipScope debug sidecar, which is broken on
# this Windows install and blocks programming entirely.
set_param labtools.enable_cs_server false

# Connect to hw_server
puts "Connecting to hardware server..."
if {[catch {connect_hw_server -url TCP:localhost:3121} err]} {
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

# Verify configuration-done status using properties that exist on Artix-7 hw_device.
refresh_hw_device $fpga_device
set done_ir [get_property REGISTER.IR.BIT5_DONE $fpga_device]
set done_internal [get_property REGISTER.CONFIG_STATUS.BIT13_DONE_INTERNAL_SIGNAL_STATUS $fpga_device]
set done_pin [get_property REGISTER.CONFIG_STATUS.BIT14_DONE_PIN $fpga_device]
set eos_status [get_property REGISTER.CONFIG_STATUS.BIT04_END_OF_STARTUP_(EOS)_STATUS $fpga_device]
set usercode_status [get_property REGISTER.USERCODE $fpga_device]
set usr_access_status [get_property REGISTER.USR_ACCESS $fpga_device]

set is_programmed [expr {$done_ir eq "1" && $done_internal eq "1" && $done_pin eq "1" && $eos_status eq "1"}]
set expected_hex [ax7203_normalize_hex $expected_build_id]
set actual_usr_access_hex [ax7203_normalize_hex $usr_access_status]
set actual_usercode_hex [ax7203_normalize_hex $usercode_status]
set build_id_matches [expr {$actual_usr_access_hex eq $expected_hex}]
set usercode_matches [expr {$actual_usercode_hex eq $expected_hex}]

if {$is_programmed} {
    puts "Verification: DONE=1, DONE_PIN=1, EOS=1"
} else {
    puts "WARNING: Configuration status is unexpected"
    puts "  DONE_IR=$done_ir DONE_INT=$done_internal DONE_PIN=$done_pin EOS=$eos_status"
}
puts "Readback: USERCODE=$usercode_status USR_ACCESS=$usr_access_status"
if {$build_id_matches} {
    puts "Readback build ID matches expected value via USR_ACCESS: $expected_build_id"
} else {
    puts "ERROR: Readback build ID mismatch"
    puts "  expected=$expected_build_id actual_usr_access=0x$actual_usr_access_hex"
}
if {$usercode_matches} {
    puts "Readback USERCODE also matches expected value: $expected_build_id"
} else {
    puts "INFO: USERCODE readback differs from expected build ID"
    puts "  expected=$expected_build_id actual_usercode=0x$actual_usercode_hex"
}

# Close hardware target
close_hw_target

set evidence_file "$script_dir/../.sisyphus/evidence/task-8-jtag-program.log"
ax7203_write_evidence $evidence_file [list \
    "JTAG Programming: SUCCESS" \
    "Bitstream: $bitstream_file" \
    "Device: [get_property NAME $fpga_device]" \
    "Is Programmed: $is_programmed" \
    "TopModule: $top_module" \
    "ExpectedBuildID: $expected_build_id" \
    "USERCODE: $usercode_status" \
    "USR_ACCESS: $usr_access_status" \
    "BuildIDMatches: $build_id_matches" \
    "UsercodeMatches: $usercode_matches" \
    "DONE_IR: $done_ir" \
    "DONE_INTERNAL: $done_internal" \
    "DONE_PIN: $done_pin" \
    "EOS: $eos_status" \
    "Timestamp: [clock format [clock seconds]]"]

if {!$is_programmed} {
    puts "ERROR: Device did not report DONE/EOS after programming."
    exit 1
}

if {!$build_id_matches} {
    puts "ERROR: Programmed device build ID does not match the selected bitstream."
    exit 1
}

puts ""
puts "Next steps:"
puts "  1. Check UART output for boot messages"
puts "  2. Verify LED heartbeat"
puts "  3. Run smoke tests"

exit 0
