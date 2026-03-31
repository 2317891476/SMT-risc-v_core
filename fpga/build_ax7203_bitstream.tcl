# build_ax7203_bitstream.tcl
# Build bitstream for ALINX AX7203
# Usage: vivado -mode batch -source fpga/build_ax7203_bitstream.tcl

set script_dir [file dirname [info script]]
source "$script_dir/flow_common.tcl"

set project_dir [file normalize [ax7203_env_or_default PROJECT_DIR "$script_dir/../build/ax7203"]]
set project_name "adam_riscv_ax7203"
set project_file "$project_dir/$project_name.xpr"

# Parse arguments
set target_part [ax7203_env_or_default TARGET_PART "xc7a200tfbg484-2"]
set enable_rocc [ax7203_env_or_default AX7203_ENABLE_ROCC 0]
set enable_mem_subsys [ax7203_env_or_default AX7203_ENABLE_MEM_SUBSYS 0]
set smt_mode [ax7203_env_or_default AX7203_SMT_MODE 0]
set synth_jobs [ax7203_env_or_default AX7203_SYNTH_JOBS 4]
set impl_jobs [ax7203_env_or_default AX7203_IMPL_JOBS 4]
set synth_timeout_min [ax7203_env_or_default AX7203_SYNTH_TIMEOUT_MIN 15]
set impl_timeout_min [ax7203_env_or_default AX7203_IMPL_TIMEOUT_MIN 45]
set is_compare 0
if {[info exists ::env(TARGET_PART)]} {
    set target_part $::env(TARGET_PART)
}
if {[info exists ::env(COMPARE_BUILD)]} {
    set is_compare $::env(COMPARE_BUILD)
}

puts "Opening project: $project_name"
puts "Target part: $target_part"
puts "ENABLE_ROCC_ACCEL: $enable_rocc"
puts "ENABLE_MEM_SUBSYS: $enable_mem_subsys"
puts "SMT_MODE: $smt_mode"
puts "Synthesis jobs: $synth_jobs"
puts "Implementation jobs: $impl_jobs"
puts "Synthesis timeout: ${synth_timeout_min} minute(s)"
puts "Implementation timeout: ${impl_timeout_min} minute(s)"

if {![file exists $project_file]} {
    puts "ERROR: Project not found: $project_file"
    puts "Run project creation first: vivado -mode batch -source fpga/create_project_ax7203.tcl"
    exit 1
}

# Open project
open_project $project_file

# Update part if different
set current_part [get_property part [current_project]]
if {$current_part != $target_part} {
    puts "Updating part from $current_part to $target_part"
    set_property part $target_part [current_project]
}

set_property verilog_define [list \
    FPGA_MODE=1 \
    ENABLE_ROCC_ACCEL=$enable_rocc \
    ENABLE_MEM_SUBSYS=$enable_mem_subsys \
    SMT_MODE=$smt_mode \
] [get_filesets sources_1]

# Reset runs
reset_run synth_1
reset_run impl_1

# Run synthesis
puts "Starting synthesis..."
launch_runs synth_1 -jobs $synth_jobs
if {[catch {
    ax7203_wait_run_with_timeout synth_1 [expr {$synth_timeout_min * 60}]
} synth_err]} {
    puts "ERROR: $synth_err"
    exit 1
}

# Check synthesis results
set synth_status [get_property status [get_runs synth_1]]
if {$synth_status != "synth_design Complete!"} {
    puts "ERROR: Synthesis failed with status: $synth_status"
    exit 1
}

puts "Synthesis completed successfully!"

set report_dir "$project_dir/reports"
set checkpoint_dir "$project_dir/checkpoints"
file mkdir $report_dir
file mkdir $checkpoint_dir

open_run synth_1
report_utilization -file $report_dir/synth_utilization.rpt
report_utilization -hierarchical -hierarchical_depth 3 -file $report_dir/synth_utilization_hier.rpt
report_timing_summary -file $report_dir/synth_timing_summary.rpt -max_paths 20
ax7203_copy_first_match "$project_dir/$project_name.runs/synth_1/*.dcp" "$checkpoint_dir/${project_name}_post_synth.dcp"

# Run implementation
puts "Starting implementation..."
launch_runs impl_1 -to_step write_bitstream -jobs $impl_jobs
if {[catch {
    ax7203_wait_run_with_timeout impl_1 [expr {$impl_timeout_min * 60}]
} impl_err]} {
    puts "ERROR: $impl_err"
    exit 1
}

# Check implementation results
set impl_status [get_property status [get_runs impl_1]]
if {$impl_status != "write_bitstream Complete!"} {
    puts "ERROR: Implementation failed with status: $impl_status"
    exit 1
}

puts "Implementation completed successfully!"

# Generate reports
puts "Generating reports..."

# Timing report
open_run impl_1
report_timing_summary -file $report_dir/timing_summary.rpt -max_paths 10
report_timing -file $report_dir/timing_detail.rpt -max_paths 100
report_clock_interaction -file $report_dir/clock_interaction.rpt

# Utilization report
report_utilization -file $report_dir/utilization.rpt
report_utilization -hierarchical -hierarchical_depth 3 -file $report_dir/utilization_hier.rpt
ax7203_copy_first_match "$project_dir/$project_name.runs/impl_1/*.dcp" "$checkpoint_dir/${project_name}_post_route.dcp"

# Check for unconstrained paths using the generated timing report. Vivado 2023.2
# in this environment does not support `get_timing_paths -unconstrained`.
set num_unconstrained -1
if {[file exists $report_dir/timing_summary.rpt]} {
    set timing_fh [open $report_dir/timing_summary.rpt r]
    set timing_text [read $timing_fh]
    close $timing_fh
    if {[regexp {checking unconstrained_internal_endpoints \(([0-9]+)\)} $timing_text -> unconstrained_count]} {
        set num_unconstrained $unconstrained_count
    }
}

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
ax7203_write_evidence $evidence_file [list \
    "Build: SUCCESS" \
    "Part: $target_part" \
    "ENABLE_ROCC_ACCEL: $enable_rocc" \
    "ENABLE_MEM_SUBSYS: $enable_mem_subsys" \
    "SMT_MODE: $smt_mode" \
    "Synthesis: $synth_status" \
    "Implementation: $impl_status" \
    "SynthesisJobs: $synth_jobs" \
    "ImplementationJobs: $impl_jobs" \
    "SynthesisTimeoutMinutes: $synth_timeout_min" \
    "ImplementationTimeoutMinutes: $impl_timeout_min" \
    "Unconstrained paths: $num_unconstrained" \
    "Timestamp: [clock format [clock seconds]]" \
]

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
close_project
exit 0
