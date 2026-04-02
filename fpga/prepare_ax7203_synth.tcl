# prepare_ax7203_synth.tcl
# Prepare the AX7203 synth_1 generated Tcl without launching the fragile
# Windows run wrapper. The caller can then invoke the generated Tcl directly.

set script_dir [file dirname [info script]]
source "$script_dir/flow_common.tcl"

set project_name "adam_riscv_ax7203"
set project_dir [file normalize [ax7203_env_or_default PROJECT_DIR "$script_dir/../build/ax7203"]]
set target_part [ax7203_env_or_default TARGET_PART "xc7a200tfbg484-2"]
set enable_rocc [ax7203_env_or_default AX7203_ENABLE_ROCC 0]
set enable_mem_subsys [ax7203_env_or_default AX7203_ENABLE_MEM_SUBSYS 0]
set smt_mode [ax7203_env_or_default AX7203_SMT_MODE 0]
set synth_jobs [ax7203_env_or_default AX7203_SYNTH_JOBS 4]
set top_module [ax7203_env_or_default AX7203_TOP_MODULE "adam_riscv_ax7203_top"]
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
puts "Top module: $top_module"
puts "Synthesis jobs: $synth_jobs"

puts "Refreshing board ROM image before synthesis..."
ax7203_build_board_rom $script_dir

open_project $project_file

set current_part [get_property part [current_project]]
if {$current_part != $target_part} {
    puts "Updating part from $current_part to $target_part"
    set_property part $target_part [current_project]
}

set_property top $top_module [get_filesets sources_1]
set_property verilog_define [list \
    FPGA_MODE=1 \
    ENABLE_ROCC_ACCEL=$enable_rocc \
    ENABLE_MEM_SUBSYS=$enable_mem_subsys \
    SMT_MODE=$smt_mode \
] [get_filesets sources_1]
update_compile_order -fileset sources_1

foreach ip_file [get_files -quiet *.xci] {
    catch {set_property GENERATE_SYNTH_CHECKPOINT 0 $ip_file}
}

set runs_dir "$project_dir/${project_name}.runs"
file mkdir "$project_dir/reports"
file mkdir "$project_dir/checkpoints"

catch {set_param general.maxThreads $synth_jobs}
catch {close_design}

ax7203_clear_run_markers $runs_dir
ax7203_reset_runs_matching synth_1
ax7203_reset_runs_matching impl_1

puts "Generating synth_1 scripts only..."
launch_runs synth_1 -jobs $synth_jobs -scripts_only

set synth_run_script "$runs_dir/synth_1/${top_module}.tcl"
if {![file exists $synth_run_script]} {
    set synth_run_script "$runs_dir/synth_1/${project_name}_top.tcl"
}
if {![file exists $synth_run_script]} {
    set synth_run_script "$runs_dir/synth_1/adam_riscv_ax7203_top.tcl"
}
if {![file exists $synth_run_script]} {
    puts "ERROR: Expected synth_1 Tcl script was not generated."
    exit 1
}

puts "SynthRunScript: $synth_run_script"
puts "SynthRunDir: [file dirname $synth_run_script]"
close_project
exit 0
