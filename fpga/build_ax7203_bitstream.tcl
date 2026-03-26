# build_ax7203_bitstream.tcl
# Build bitstream for ALINX AX7203
# Usage: vivado -mode batch -source fpga/build_ax7203_bitstream.tcl

set script_dir [file dirname [info script]]
set project_dir "$script_dir/../build/ax7203"
set project_name "adam_riscv_ax7203"

# Parse arguments
set target_part "xc7a200t-2fbg484i"
set is_compare 0
if {[info exists ::env(TARGET_PART)]} {
    set target_part $::env(TARGET_PART)
}
if {[info exists ::env(COMPARE_BUILD)]} {
    set is_compare $::env(COMPARE_BUILD)
}

puts "Opening project: $project_name"
puts "Target part: $target_part"

# Open project
open_project $project_dir/$project_name.xpr

# Update part if different
set current_part [get_property part [current_project]]
if {$current_part != $target_part} {
    puts "Updating part from $current_part to $target_part"
    set_property part $target_part [current_project]
}

# Reset runs
reset_run synth_1
reset_run impl_1

# Run synthesis
puts "Starting synthesis..."
launch_runs synth_1 -jobs 4
wait_on_run synth_1

# Check synthesis results
set synth_status [get_property status [get_runs synth_1]]
if {$synth_status != "synth_design Complete!"} {
    puts "ERROR: Synthesis failed with status: $synth_status"
    exit 1
}

puts "Synthesis completed successfully!"

# Run implementation
puts "Starting implementation..."
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1

# Check implementation results
set impl_status [get_property status [get_runs impl_1]]
if {$impl_status != "write_bitstream Complete!"} {
    puts "ERROR: Implementation failed with status: $impl_status"
    exit 1
}

puts "Implementation completed successfully!"

# Generate reports
set report_dir "$project_dir/reports"
file mkdir $report_dir

puts "Generating reports..."

# Timing report
open_run impl_1
report_timing_summary -file $report_dir/timing_summary.rpt -max_paths 10
report_timing -file $report_dir/timing_detail.rpt -max_paths 100
report_clock_interaction -file $report_dir/clock_interaction.rpt

# Utilization report
report_utilization -file $report_dir/utilization.rpt

# Check for unconstrained paths
set unconstrained [get_timing_paths -unconstrained]
set num_unconstrained [llength $unconstrained]

puts "Report Summary:"
puts "  - Timing summary: $report_dir/timing_summary.rpt"
puts "  - Utilization: $report_dir/utilization.rpt"
puts "  - Unconstrained paths: $num_unconstrained"

# Copy bitstream to standard location
set bitstream [glob $project_dir/$project_name.runs/impl_1/*.bit]
file copy -force $bitstream $project_dir/${project_name}_${target_part}.bit

puts "Bitstream: $project_dir/${project_name}_${target_part}.bit"

# Save evidence
set evidence_file "$script_dir/../.sisyphus/evidence/task-2-build-bitstream.log"
set fh [open $evidence_file w]
puts $fh "Build: SUCCESS"
puts $fh "Part: $target_part"
puts $fh "Synthesis: $synth_status"
puts $fh "Implementation: $impl_status"
puts $fh "Unconstrained paths: $num_unconstrained"
puts $fh "Timestamp: [clock format [clock seconds]]"
close $fh

# Check for timing violations
set wns [get_property STATS.WNS [get_runs impl_1]]
set tns [get_property STATS.TNS [get_runs impl_1]]
set whs [get_property STATS.WHS [get_runs impl_1]]

puts "Timing Results:"
puts "  WNS: $wns"
puts "  TNS: $tns"
puts "  WHS: $whs"

if {$wns < 0 || $whs < 0} {
    puts "WARNING: Timing violations detected!"
    puts "  Setup violations: WNS = $wns"
    puts "  Hold violations: WHS = $whs"
    if {!$is_compare} {
        puts "ERROR: Primary target ($target_part) has timing violations. Fix before continuing."
        exit 1
    }
}

if {$num_unconstrained > 0} {
    puts "ERROR: $num_unconstrained unconstrained paths found. Add constraints and rebuild."
    exit 1
}

puts "Build completed successfully!"
exit 0
