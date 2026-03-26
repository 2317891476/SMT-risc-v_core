# report_ax7203_timing.tcl
# Generate detailed timing reports for ALINX AX7203
# Usage: vivado -mode batch -source fpga/report_ax7203_timing.tcl

set script_dir [file dirname [info script]]
set project_dir "$script_dir/../build/ax7203"
set project_name "adam_riscv_ax7203"
set report_dir "$project_dir/reports"

# Parse arguments
set target_part "xc7a200t-2fbg484i"
if {[info exists ::env(TARGET_PART)]} {
    set target_part $::env(TARGET_PART)
}

puts "Generating timing reports..."
puts "Target part: $target_part"

# Open project
open_project $project_dir/$project_name.xpr

# Ensure implementation run is open
if {[catch {open_run impl_1} err]} {
    puts "ERROR: Could not open implementation run. Run build first."
    puts $err
    exit 1
}

# Create report directory
file mkdir $report_dir

# Generate comprehensive timing reports
puts "Generating timing_summary.rpt..."
report_timing_summary \
    -delay_type min_max \
    -report_unconstrained \
    -check_timing_verbose \
    -max_paths 100 \
    -input_pins \
    -routable_nets \
    -file $report_dir/timing_summary_${target_part}.rpt

puts "Generating timing_setup.rpt..."
report_timing \
    -delay_type max \
    -max_paths 100 \
    -sort_by group \
    -file $report_dir/timing_setup_${target_part}.rpt

puts "Generating timing_hold.rpt..."
report_timing \
    -delay_type min \
    -max_paths 100 \
    -sort_by group \
    -file $report_dir/timing_hold_${target_part}.rpt

puts "Generating clock_interaction.rpt..."
report_clock_interaction \
    -delay_type min_max \
    -significant_digits 3 \
    -file $report_dir/clock_interaction_${target_part}.rpt

puts "Generating timing_exceptions.rpt..."
report_exceptions \
    -file $report_dir/timing_exceptions_${target_part}.rpt

puts "Generating check_timing.rpt..."
check_timing \
    -file $report_dir/check_timing_${target_part}.rpt

# Extract key metrics
set timing_summary [report_timing_summary -return_string]
set wns [regexp {WNS.*: ([-\d\.]+)} $timing_summary match wns_val]
set tns [regexp {TNS.*: ([-\d\.]+)} $timing_summary match tns_val]
set whs [regexp {WHS.*: ([-\d\.]+)} $timing_summary match whs_val]
set ths [regexp {THS.*: ([-\d\.]+)} $timing_summary match ths_val]

# Check for unconstrained paths
set check_result [check_timing -return_string]
set unconstrained_count 0
if {[regexp {Number of unconstrained paths:\s+(\d+)} $check_result match count]} {
    set unconstrained_count $count
}

puts ""
puts "Timing Report Summary ($target_part):"
puts "===================================="
if {$wns} { puts "WNS: $wns_val ns" }
if {$tns} { puts "TNS: $tns_val ns" }
if {$whs} { puts "WHS: $whs_val ns" }
if {$ths} { puts "THS: $ths_val ns" }
puts "Unconstrained paths: $unconstrained_count"
puts ""

# Determine pass/fail
set timing_pass 1
if {$wns && $wns_val < 0} {
    puts "FAIL: Setup timing violation (WNS < 0)"
    set timing_pass 0
}
if {$whs && $whs_val < 0} {
    puts "FAIL: Hold timing violation (WHS < 0)"
    set timing_pass 0
}
if {$unconstrained_count > 0} {
    puts "FAIL: $unconstrained_count unconstrained paths found"
    set timing_pass 0
}

if {$timing_pass} {
    puts "PASS: All timing checks passed!"
} else {
    puts "WARNING: Timing issues detected. Review reports in $report_dir"
}

# Save evidence
set evidence_file "$script_dir/../.sisyphus/evidence/task-2-timing-report.log"
set fh [open $evidence_file w]
puts $fh "Timing Report: GENERATED"
puts $fh "Part: $target_part"
if {$wns} { puts $fh "WNS: $wns_val" }
if {$tns} { puts $fh "TNS: $tns_val" }
if {$whs} { puts $fh "WHS: $whs_val" }
if {$ths} { puts $fh "THS: $ths_val" }
puts $fh "Unconstrained: $unconstrained_count"
puts $fh "Pass: $timing_pass"
puts $fh "Timestamp: [clock format [clock seconds]]"
close $fh

puts "Reports saved to: $report_dir"
exit 0
