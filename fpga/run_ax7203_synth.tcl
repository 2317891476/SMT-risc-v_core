# run_ax7203_synth.tcl
# Run AX7203 synthesis only with an explicit timeout gate.
# Usage: vivado -mode batch -source fpga/run_ax7203_synth.tcl

set script_dir [file dirname [info script]]
source "$script_dir/flow_common.tcl"

set project_name "adam_riscv_ax7203"
set project_dir [file normalize [ax7203_env_or_default PROJECT_DIR "$script_dir/../build/ax7203"]]
set target_part [ax7203_env_or_default TARGET_PART "xc7a200tfbg484-2"]
set enable_rocc [ax7203_env_or_default AX7203_ENABLE_ROCC 0]
set enable_mem_subsys [ax7203_env_or_default AX7203_ENABLE_MEM_SUBSYS 0]
set smt_mode [ax7203_env_or_default AX7203_SMT_MODE 0]
set synth_jobs [ax7203_env_or_default AX7203_SYNTH_JOBS 4]
set synth_timeout_min [ax7203_env_or_default AX7203_SYNTH_TIMEOUT_MIN 15]
set project_file "$project_dir/$project_name.xpr"

if {![file exists $project_file]} {
    puts "ERROR: Project not found: $project_file"
    puts "Run project creation first: vivado -mode batch -source fpga/create_project_ax7203.tcl"
    exit 1
}

puts "Opening project: $project_file"
puts "Target part: $target_part"
puts "ENABLE_ROCC_ACCEL: $enable_rocc"
puts "ENABLE_MEM_SUBSYS: $enable_mem_subsys"
puts "SMT_MODE: $smt_mode"
puts "Synthesis jobs: $synth_jobs"
puts "Synthesis timeout: ${synth_timeout_min} minute(s)"

open_project $project_file

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

reset_run synth_1
reset_run impl_1

puts "Starting synthesis..."
launch_runs synth_1 -jobs $synth_jobs

if {[catch {
    ax7203_wait_run_with_timeout synth_1 [expr {$synth_timeout_min * 60}]
} synth_err]} {
    puts "ERROR: $synth_err"
    exit 1
}

set synth_status [get_property STATUS [get_runs synth_1]]
if {$synth_status != "synth_design Complete!"} {
    puts "ERROR: Unexpected synthesis status: $synth_status"
    exit 1
}

puts "Synthesis completed successfully."

set report_dir "$project_dir/reports"
set checkpoint_dir "$project_dir/checkpoints"
file mkdir $report_dir
file mkdir $checkpoint_dir

open_run synth_1
report_utilization -file $report_dir/synth_utilization.rpt
report_utilization -hierarchical -hierarchical_depth 3 -file $report_dir/synth_utilization_hier.rpt
report_timing_summary -file $report_dir/synth_timing_summary.rpt -max_paths 20
ax7203_copy_first_match "$project_dir/$project_name.runs/synth_1/*.dcp" "$checkpoint_dir/${project_name}_post_synth.dcp"

set evidence_file "$script_dir/../.sisyphus/evidence/task-2a-synth.log"
ax7203_write_evidence $evidence_file [list \
    "Synthesis: SUCCESS" \
    "Part: $target_part" \
    "ENABLE_ROCC_ACCEL: $enable_rocc" \
    "ENABLE_MEM_SUBSYS: $enable_mem_subsys" \
    "SMT_MODE: $smt_mode" \
    "Jobs: $synth_jobs" \
    "TimeoutMinutes: $synth_timeout_min" \
    "Status: $synth_status" \
    "Timestamp: [clock format [clock seconds]]" \
]

puts "Reports:"
puts "  $report_dir/synth_utilization.rpt"
puts "  $report_dir/synth_utilization_hier.rpt"
puts "  $report_dir/synth_timing_summary.rpt"
puts "Checkpoint:"
puts "  $checkpoint_dir/${project_name}_post_synth.dcp"

close_project
exit 0
