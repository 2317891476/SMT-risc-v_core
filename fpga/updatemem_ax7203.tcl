# updatemem_ax7203.tcl
# Attempt to update BRAM contents in bitstream without re-synthesis.
# Usage: vivado -mode batch -source fpga/updatemem_ax7203.tcl

set script_dir [file dirname [info script]]
set project_dir [file normalize "$script_dir/../build/ax7203"]
set post_route_dcp "$project_dir/checkpoints/adam_riscv_ax7203_post_route.dcp"
set mmi_file "$project_dir/adam_riscv_ax7203.mmi"
set orig_bit "$project_dir/adam_riscv_ax7203_xc7a200tfbg484-2.bit"
set updated_bit "$project_dir/adam_riscv_ax7203_xc7a200tfbg484-2_updated.bit"
set hex_file [file normalize "$script_dir/../rom/mem_subsys_ram.hex"]

puts "Opening post-route checkpoint..."
open_checkpoint $post_route_dcp

puts "Generating memory info file..."
if {[catch {write_mem_info -force $mmi_file} err]} {
    puts "write_mem_info failed: $err"
    puts "Falling back to re-synthesis approach..."
    close_design
    exit 2
}

if {![file exists $mmi_file]} {
    puts "ERROR: MMI file was not created"
    close_design
    exit 2
}

puts "MMI file created: $mmi_file"
puts "MMI file size: [file size $mmi_file] bytes"

# Show what memories were found
puts "--- MMI file contents (first 50 lines) ---"
set fh [open $mmi_file r]
set line_count 0
while {[gets $fh line] >= 0 && $line_count < 50} {
    puts $line
    incr line_count
}
close $fh

close_design

# Now try updatemem
puts ""
puts "Running updatemem..."
puts "  MMI: $mmi_file"
puts "  HEX: $hex_file"
puts "  Original BIT: $orig_bit"
puts "  Updated BIT: $updated_bit"

if {[catch {
    exec updatemem -force \
        -meminfo $mmi_file \
        -data $hex_file \
        -bit $orig_bit \
        -out $updated_bit \
        -proc dummy
} err]} {
    puts "updatemem failed: $err"
    puts "Will need to re-synthesize..."
    exit 2
}

if {[file exists $updated_bit]} {
    puts ""
    puts "SUCCESS: Updated bitstream created!"
    puts "  $updated_bit"
    puts "  Size: [file size $updated_bit] bytes"
} else {
    puts "ERROR: Updated bitstream was not created"
    exit 2
}

exit 0
