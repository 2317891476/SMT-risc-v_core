# run_ax7203_synth.tcl
# Run AX7203 synthesis inside a single Vivado batch session.
# Usage: vivado -mode batch -source fpga/run_ax7203_synth.tcl

set script_dir [file dirname [info script]]
source "$script_dir/flow_common.tcl"

set project_name "adam_riscv_ax7203"
set project_dir [file normalize [ax7203_env_or_default PROJECT_DIR "$script_dir/../build/ax7203"]]
set target_part [ax7203_env_or_default TARGET_PART "xc7a200tfbg484-2"]
set enable_rocc [ax7203_env_or_default AX7203_ENABLE_ROCC 0]
set enable_mem_subsys [ax7203_env_or_default AX7203_ENABLE_MEM_SUBSYS 1]
set enable_ddr3 [ax7203_env_or_default AX7203_ENABLE_DDR3 1]
set smt_mode [ax7203_env_or_default AX7203_SMT_MODE 1]
set rs_depth [expr {[ax7203_env_or_default AX7203_RS_DEPTH 16] + 0}]
set fetch_buffer_depth [expr {[ax7203_env_or_default AX7203_FETCH_BUFFER_DEPTH 16] + 0}]
set rs_idx_w [expr {[ax7203_env_or_default AX7203_RS_IDX_W [ax7203_clog2 $rs_depth]] + 0}]
set core_clk_mhz [expr {double([ax7203_env_or_default AX7203_CORE_CLK_MHZ 25.0])}]
set uart_clk_div [expr {[ax7203_env_or_default AX7203_UART_CLK_DIV [ax7203_uart_clk_div $core_clk_mhz]] + 0}]
set synth_jobs [ax7203_env_or_default AX7203_SYNTH_JOBS 4]
set synth_timeout_min [ax7203_env_or_default AX7203_SYNTH_TIMEOUT_MIN 15]
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
puts "RS depth: $rs_depth"
puts "RS idx width: $rs_idx_w"
puts "Fetch buffer depth: $fetch_buffer_depth"
puts "Core clock: ${core_clk_mhz} MHz"
puts "UART clock divider: $uart_clk_div"
puts "Top module: $top_module"
puts "Synthesis jobs: $synth_jobs"
puts "Synthesis timeout budget: ${synth_timeout_min} minute(s)"

puts "Refreshing board ROM image before synthesis..."
ax7203_build_board_rom $script_dir

if {$enable_mem_subsys} {
    set merge_py "$script_dir/scripts/merge_hex_for_mem_subsys.py"
    if {[file exists $merge_py]} {
        puts "Re-merging mem_subsys_ram.hex from updated inst/data hex..."
        if {[catch {exec python $merge_py} merge_out]} {
            puts "WARNING: merge_hex_for_mem_subsys.py failed: $merge_out"
        } else {
            puts $merge_out
        }
    }
}

open_project $project_file

set current_part [get_property part [current_project]]
if {$current_part != $target_part} {
    puts "Updating part from $current_part to $target_part"
    set_property part $target_part [current_project]
}

if {$enable_mem_subsys} {
    set l2_pt "L2_PASSTHROUGH=1"
} else {
    set l2_pt ""
}
if {$enable_ddr3} {
    set ddr3_def "ENABLE_DDR3=1"
} else {
    set ddr3_def ""
}
set_property top $top_module [get_filesets sources_1]
set_property verilog_define [list \
    FPGA_MODE=1 \
    ENABLE_ROCC_ACCEL=$enable_rocc \
    ENABLE_MEM_SUBSYS=$enable_mem_subsys \
    SMT_MODE=$smt_mode \
    FPGA_SCOREBOARD_RS_DEPTH=$rs_depth \
    FPGA_SCOREBOARD_RS_IDX_W=$rs_idx_w \
    FPGA_FETCH_BUFFER_DEPTH=$fetch_buffer_depth \
    FPGA_UART_CLK_DIV=$uart_clk_div \
    {*}$l2_pt \
    {*}$ddr3_def \
] [get_filesets sources_1]
update_compile_order -fileset sources_1

foreach ip_file [get_files -quiet *.xci] {
    catch {set_property GENERATE_SYNTH_CHECKPOINT 0 $ip_file}
}

set report_dir "$project_dir/reports"
set checkpoint_dir "$project_dir/checkpoints"
set runs_dir "$project_dir/${project_name}.runs"
set synth_checkpoint "$checkpoint_dir/${project_name}_post_synth.dcp"
set synth_util_rpt "$report_dir/synth_utilization.rpt"
set synth_util_hier_rpt "$report_dir/synth_utilization_hier.rpt"
set synth_timing_rpt "$report_dir/synth_timing_summary.rpt"
file mkdir $report_dir
file mkdir $checkpoint_dir

catch {set_param general.maxThreads $synth_jobs}
catch {close_design}

ax7203_clear_run_markers $runs_dir
ax7203_reset_runs_matching synth_1
ax7203_reset_runs_matching impl_1

set synth_start [clock seconds]
puts "Running manual synth_design in the current Vivado session..."
catch {reset_run synth_1}
catch {close_design}
synth_design \
    -top $top_module \
    -part $target_part \
    -flatten_hierarchy none \
    -directive RuntimeOptimized \
    -fsm_extraction off
write_checkpoint -force $synth_checkpoint
report_utilization -file $synth_util_rpt
report_utilization -hierarchical -hierarchical_depth 3 -file $synth_util_hier_rpt
report_timing_summary -file $synth_timing_rpt -max_paths 10
set synth_elapsed [expr {[clock seconds] - $synth_start}]
set synth_elapsed_min [expr {$synth_elapsed / 60.0}]

puts "Synthesis completed in [format %.2f $synth_elapsed_min] minute(s)."
if {$synth_elapsed > ($synth_timeout_min * 60)} {
    puts "ERROR: Synthesis exceeded timeout budget of ${synth_timeout_min} minute(s)."
    exit 1
}

set synth_run_dcp "$runs_dir/synth_1/${top_module}.dcp"
if {![file exists $synth_run_dcp]} {
    set synth_run_dcp "$runs_dir/synth_1/${project_name}_top.dcp"
}
if {![file exists $synth_run_dcp]} {
    set synth_run_dcp "$runs_dir/synth_1/adam_riscv_ax7203_top.dcp"
}
if {![file exists $synth_run_dcp]} {
    puts "WARNING: synth_1 run checkpoint not found under $runs_dir; using manual checkpoint $synth_checkpoint"
    set synth_run_dcp $synth_checkpoint
}

set evidence_file "$script_dir/../.sisyphus/evidence/task-2a-synth.log"
ax7203_write_evidence $evidence_file [list \
    "Synthesis: SUCCESS" \
    "Mode: manual_synth_design" \
    "Part: $target_part" \
    "ENABLE_ROCC_ACCEL: $enable_rocc" \
    "ENABLE_MEM_SUBSYS: $enable_mem_subsys" \
    "SMT_MODE: $smt_mode" \
    "RSDepth: $rs_depth" \
    "RSIdxW: $rs_idx_w" \
    "FetchBufferDepth: $fetch_buffer_depth" \
    "CoreClkMHz: $core_clk_mhz" \
    "UartClkDiv: $uart_clk_div" \
    "TopModule: $top_module" \
    "Jobs: $synth_jobs" \
    "TimeoutMinutes: $synth_timeout_min" \
    "ElapsedSeconds: $synth_elapsed" \
    "SynthRunDcp: $synth_run_dcp" \
    "Timestamp: [clock format [clock seconds]]" \
]

puts "Reports:"
puts "  $synth_util_rpt"
puts "  $synth_util_hier_rpt"
puts "  $synth_timing_rpt"
puts "Checkpoint:"
puts "  $synth_checkpoint"

catch {close_design}
close_project
exit 0
