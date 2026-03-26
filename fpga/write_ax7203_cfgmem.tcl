# write_ax7203_cfgmem.tcl
# Generate configuration memory files for Flash programming
# Usage: vivado -mode batch -source fpga/write_ax7203_cfgmem.tcl

set script_dir [file dirname [info script]]
set project_dir "$script_dir/../build/ax7203"
set project_name "adam_riscv_ax7203"

# Parse arguments
set target_part "xc7a200t-2fbg484i"
if {[info exists ::env(TARGET_PART)]} {
    set target_part $::env(TARGET_PART)
}

set bitstream_file "$project_dir/${project_name}_${target_part}.bit"
set cfgmem_dir "$project_dir/cfgmem"

# Check if bitstream exists
if {![file exists $bitstream_file]} {
    puts "ERROR: Bitstream not found: $bitstream_file"
    puts "Run build first: vivado -mode batch -source fpga/build_ax7203_bitstream.tcl"
    exit 1
}

puts "Generating configuration memory files..."
puts "Bitstream: $bitstream_file"
puts "Target Flash: W25Q256 (256Mb / 32MB)"

# Create cfgmem directory
file mkdir $cfgmem_dir

# Open project (needed for write_cfgmem)
open_project $project_dir/$project_name.xpr

# Write configuration memory files
# Format: SPIx4 (Quad SPI)
# Interface: BPIx16 is for parallel flash, SPIx4 for QSPI

set cfgmem_base "$cfgmem_dir/${project_name}_${target_part}_cfg"

puts "Writing .mcs file (Master Configuration Set)..."
write_cfgmem -force \
    -format mcs \
    -size 256 \
    -interface SPIx4 \
    -loadbit "up 0x0 $bitstream_file" \
    -file ${cfgmem_base}.mcs

puts "Writing .bin file (Binary)..."
write_cfgmem -force \
    -format bin \
    -size 256 \
    -interface SPIx4 \
    -loadbit "up 0x0 $bitstream_file" \
    -file ${cfgmem_base}.bin

puts "Writing .prm file (Programming)..."
write_cfgmem -force \
    -format hex \
    -size 256 \
    -interface SPIx4 \
    -loadbit "up 0x0 $bitstream_file" \
    -file ${cfgmem_base}.hex

puts ""
puts "Configuration memory files generated:"
puts "  MCS: ${cfgmem_base}.mcs"
puts "  BIN: ${cfgmem_base}.bin"
puts "  HEX: ${cfgmem_base}.hex"

# Get file sizes
set mcs_size [file size ${cfgmem_base}.mcs]
set bin_size [file size ${cfgmem_base}.bin]

puts ""
puts "File sizes:"
puts "  MCS: $mcs_size bytes"
puts "  BIN: $bin_size bytes"
puts "  Flash capacity: 32MB (enough for bitstream)"

# Verify files were created
set all_exist 1
foreach ext {mcs bin hex} {
    set fname ${cfgmem_base}.${ext}
    if {![file exists $fname]} {
        puts "ERROR: Failed to create $fname"
        set all_exist 0
    }
}

if {!$all_exist} {
    exit 1
}

# Save evidence
set evidence_file "$script_dir/../.sisyphus/evidence/task-13-cfgmem.log"
set fh [open $evidence_file w]
puts $fh "Configuration Memory: GENERATED"
puts $fh "Bitstream: $bitstream_file"
puts $fh "MCS: ${cfgmem_base}.mcs ($mcs_size bytes)"
puts $fh "BIN: ${cfgmem_base}.bin ($bin_size bytes)"
puts $fh "Timestamp: [clock format [clock seconds]]"
close $fh

puts ""
puts "Next step: Program Flash"
puts "  vivado -mode batch -source fpga/program_ax7203_flash.tcl"

exit 0
