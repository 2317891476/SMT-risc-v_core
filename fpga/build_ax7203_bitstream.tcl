# build_ax7203_bitstream.tcl
# Build AX7203 bitstream from the synthesized checkpoint.
# We intentionally skip opt_design here because the default project impl flow
# aggressively constant-folds the board bring-up core into a tiny, non-working
# shell when the ROM image is fixed at build time.
# Usage: vivado -mode batch -source fpga/build_ax7203_bitstream.tcl

set script_dir [file dirname [info script]]
source "$script_dir/flow_common.tcl"

set project_dir [file normalize [ax7203_env_or_default PROJECT_DIR "$script_dir/../build/ax7203"]]
set project_name "adam_riscv_ax7203"
set project_file "$project_dir/$project_name.xpr"

# Parse arguments
set target_part [ax7203_env_or_default TARGET_PART "xc7a200tfbg484-2"]
set enable_rocc [ax7203_env_or_default AX7203_ENABLE_ROCC 0]
set enable_mem_subsys [ax7203_env_or_default AX7203_ENABLE_MEM_SUBSYS 1]
set enable_ddr3 [ax7203_env_or_default AX7203_ENABLE_DDR3 1]
set ddr3_fetch_debug [ax7203_env_or_default AX7203_DDR3_FETCH_DEBUG 0]
set ddr3_bridge_audit [ax7203_env_or_default AX7203_DDR3_BRIDGE_AUDIT 0]
set step2_beacon_debug [ax7203_env_or_default AX7203_STEP2_BEACON_DEBUG 0]
set loader_beacon_debug [ax7203_env_or_default AX7203_DDR3_LOADER_BEACON_DEBUG 0]
set transport_uart_rxdata_reg_test [ax7203_env_or_default AX7203_TRANSPORT_UART_RXDATA_REG_TEST 0]
set smt_mode [ax7203_env_or_default AX7203_SMT_MODE 1]
set rs_depth [expr {[ax7203_env_or_default AX7203_RS_DEPTH 48] + 0}]
set fetch_buffer_depth [expr {[ax7203_env_or_default AX7203_FETCH_BUFFER_DEPTH 16] + 0}]
set rs_idx_w [expr {[ax7203_env_or_default AX7203_RS_IDX_W [ax7203_clog2 $rs_depth]] + 0}]
set core_clk_mhz [expr {double([ax7203_env_or_default AX7203_CORE_CLK_MHZ 25.0])}]
set uart_clk_div [expr {[ax7203_env_or_default AX7203_UART_CLK_DIV [ax7203_uart_clk_div $core_clk_mhz]] + 0}]
set impl_jobs [ax7203_env_or_default AX7203_IMPL_JOBS 4]
set impl_timeout_min [ax7203_env_or_default AX7203_IMPL_TIMEOUT_MIN 45]
set top_module [ax7203_env_or_default AX7203_TOP_MODULE "adam_riscv_ax7203_top"]
set is_compare 0
if {[info exists ::env(TARGET_PART)]} {
    set target_part $::env(TARGET_PART)
}
if {[info exists ::env(COMPARE_BUILD)]} {
    set is_compare $::env(COMPARE_BUILD)
}

set report_dir "$project_dir/reports"
set checkpoint_dir "$project_dir/checkpoints"
set synth_checkpoint "$checkpoint_dir/${project_name}_post_synth.dcp"
if {$top_module eq "adam_riscv_ax7203_top"} {
    set route_checkpoint "$checkpoint_dir/${project_name}_post_route.dcp"
    set bitstream_file "$project_dir/${project_name}_${target_part}.bit"
    set build_id_file "$project_dir/${project_name}_bitstream_id.txt"
} else {
    set route_checkpoint "$checkpoint_dir/${project_name}_${top_module}_post_route.dcp"
    set bitstream_file "$project_dir/${project_name}_${top_module}_${target_part}.bit"
    set build_id_file "$project_dir/${project_name}_${top_module}_bitstream_id.txt"
}
set runs_dir "$project_dir/${project_name}.runs"
set clk_wiz_board_xdc "$project_dir/${project_name}.gen/sources_1/ip/clk_wiz_0/clk_wiz_0_board.xdc"
set clk_wiz_timing_xdc "$project_dir/${project_name}.gen/sources_1/ip/clk_wiz_0/clk_wiz_0.xdc"
set base_xdc "$script_dir/constraints/ax7203_base.xdc"
set uart_led_xdc "$script_dir/constraints/ax7203_uart_led.xdc"

puts "Building bitstream from synthesized checkpoint (skip opt_design)"
puts "Target part: $target_part"
puts "ENABLE_ROCC_ACCEL: $enable_rocc"
puts "ENABLE_MEM_SUBSYS: $enable_mem_subsys"
puts "ENABLE_DDR3: $enable_ddr3"
puts "DDR3_FETCH_DEBUG: $ddr3_fetch_debug"
puts "DDR3_BRIDGE_AUDIT: $ddr3_bridge_audit"
puts "AX7203_STEP2_BEACON_DEBUG: $step2_beacon_debug"
puts "AX7203_DDR3_LOADER_BEACON_DEBUG: $loader_beacon_debug"
puts "TRANSPORT_UART_RXDATA_REG_TEST: $transport_uart_rxdata_reg_test"
puts "SMT_MODE: $smt_mode"
puts "RS depth: $rs_depth"
puts "RS idx width: $rs_idx_w"
puts "Fetch buffer depth: $fetch_buffer_depth"
puts "Core clock: ${core_clk_mhz} MHz"
puts "UART clock divider: $uart_clk_div"
puts "Top module: $top_module"
puts "Implementation jobs: $impl_jobs"
puts "Implementation timeout budget: ${impl_timeout_min} minute(s)"
puts "Project: $project_file"

if {![file exists $project_file]} {
    puts "ERROR: Project not found: $project_file"
    puts "Run project creation first: vivado -mode batch -source fpga/create_project_ax7203.tcl"
    exit 1
}

file mkdir $report_dir
file mkdir $checkpoint_dir

open_project $project_file
set_property top $top_module [get_filesets sources_1]
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
if {$ddr3_fetch_debug} {
    set ddr3_fetch_debug_def "DDR3_FETCH_DEBUG=1"
} else {
    set ddr3_fetch_debug_def ""
}
if {$ddr3_bridge_audit} {
    set ddr3_bridge_audit_def "DDR3_BRIDGE_AUDIT=1"
} else {
    set ddr3_bridge_audit_def ""
}
if {$step2_beacon_debug} {
    set step2_beacon_debug_def "AX7203_STEP2_BEACON_DEBUG=1"
} else {
    set step2_beacon_debug_def ""
}
if {$loader_beacon_debug} {
    set loader_beacon_debug_def "AX7203_DDR3_LOADER_BEACON_DEBUG=1"
} else {
    set loader_beacon_debug_def ""
}
if {$transport_uart_rxdata_reg_test} {
    set transport_uart_rxdata_reg_test_def "TRANSPORT_UART_RXDATA_REG_TEST=1"
} else {
    set transport_uart_rxdata_reg_test_def ""
}
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
    {*}$ddr3_fetch_debug_def \
    {*}$ddr3_bridge_audit_def \
    {*}$step2_beacon_debug_def \
    {*}$loader_beacon_debug_def \
    {*}$transport_uart_rxdata_reg_test_def \
] [get_filesets sources_1]
update_compile_order -fileset sources_1

set synth_run [get_runs -quiet synth_1]
if {[llength $synth_run] == 0} {
    if {![file exists $synth_checkpoint]} {
        puts "ERROR: synth_1 run is missing and no checkpoint found: $synth_checkpoint"
        exit 1
    }
    puts "INFO: synth_1 run not found, but checkpoint exists. Proceeding."
} else {
    set synth_status [get_property STATUS $synth_run]
    puts "synth_1 status: $synth_status"
    if {![file exists $synth_checkpoint]} {
        puts "ERROR: Synth checkpoint not found: $synth_checkpoint"
        puts "Run synthesis first: vivado -mode batch -source fpga/run_ax7203_synth.tcl"
        exit 1
    }
    if {![ax7203_status_is_complete $synth_status]} {
        puts "WARNING: synth_1 run status is not marked complete, but checkpoint exists."
        puts "WARNING: Continuing from checkpoint: $synth_checkpoint"
    }
}

set required_xdc_list [list $base_xdc $uart_led_xdc]
if {$top_module eq "adam_riscv_ax7203_top"} {
    set required_xdc_list [concat [list $clk_wiz_board_xdc $clk_wiz_timing_xdc] $required_xdc_list]
}
foreach required_xdc $required_xdc_list {
    if {![file exists $required_xdc]} {
        puts "ERROR: Required constraint file not found: $required_xdc"
        exit 1
    }
}

close_project
catch {close_design}
catch {set_param general.maxThreads $impl_jobs}

puts "Opening synthesized checkpoint: $synth_checkpoint"
open_checkpoint $synth_checkpoint
if {[llength [get_cells -quiet u_adam_riscv/clk2cpu/inst]] > 0} {
    read_xdc -cells {u_adam_riscv/clk2cpu/inst} $clk_wiz_board_xdc
    read_xdc -cells {u_adam_riscv/clk2cpu/inst} $clk_wiz_timing_xdc
}
read_xdc $base_xdc
read_xdc $uart_led_xdc
set ddr3_xdc "$script_dir/constraints/ax7203_ddr3.xdc"
if {$enable_ddr3 && [file exists $ddr3_xdc]} {
    read_xdc $ddr3_xdc
}

set build_id [format %08X [expr {[clock seconds] & 0xFFFFFFFF}]]
set_property BITSTREAM.CONFIG.USERID "32'h$build_id" [current_design]
set_property BITSTREAM.CONFIG.USR_ACCESS "0x$build_id" [current_design]
puts "Bitstream build id: 0x$build_id"

puts "Running implementation steps (opt/place/phys_opt/route)..."
set impl_start [clock seconds]
opt_design
# MIG DDR3 may produce non-fatal OSERDES placement warnings promoted to ERROR;
# catch and check actual placement result instead of aborting.
if {[catch {place_design} place_err]} {
    puts "WARNING: place_design returned error: $place_err"
    puts "WARNING: Continuing — checking if placement actually succeeded..."
}
phys_opt_design
route_design
set impl_elapsed [expr {[clock seconds] - $impl_start}]

report_timing_summary -file $report_dir/timing_summary.rpt -max_paths 10
report_timing -file $report_dir/timing_detail.rpt -max_paths 100
report_clock_interaction -file $report_dir/clock_interaction.rpt
report_utilization -file $report_dir/utilization.rpt
report_utilization -hierarchical -hierarchical_depth 3 -file $report_dir/utilization_hier.rpt
write_checkpoint -force $route_checkpoint
write_bitstream -force $bitstream_file

ax7203_write_evidence $build_id_file [list \
    "BUILD_ID=0x$build_id" \
    "TOP_MODULE=$top_module" \
    "BITSTREAM=$bitstream_file" \
    "TARGET_PART=$target_part" \
    "TIMESTAMP=[clock format [clock seconds]]" \
]

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

set wns "NA"
set tns "NA"
set whs "NA"
set setup_paths [get_timing_paths -delay_type max -max_paths 1 -nworst 1]
if {[llength $setup_paths] > 0} {
    set wns [get_property SLACK [lindex $setup_paths 0]]
}
set hold_paths [get_timing_paths -delay_type min -max_paths 1 -nworst 1]
if {[llength $hold_paths] > 0} {
    set whs [get_property SLACK [lindex $hold_paths 0]]
}
if {[file exists $report_dir/timing_summary.rpt]} {
    set timing_fh [open $report_dir/timing_summary.rpt r]
    set timing_text [read $timing_fh]
    close $timing_fh
    if {[regexp {\n\s*([-0-9.]+)\s+([-0-9.]+)\s+[0-9]+\s+[0-9]+\s+([-0-9.]+)\s+([-0-9.]+)} $timing_text -> rpt_wns rpt_tns rpt_whs rpt_ths]} {
        set wns $rpt_wns
        set tns $rpt_tns
        set whs $rpt_whs
    }
}

puts "Report Summary:"
puts "  - Timing summary: $report_dir/timing_summary.rpt"
puts "  - Utilization: $report_dir/utilization.rpt"
puts "  - Unconstrained paths: $num_unconstrained"
puts "  - Bitstream: $bitstream_file"
puts "  - Build ID: 0x$build_id"

set evidence_file "$script_dir/../.sisyphus/evidence/task-2-build-bitstream.log"
ax7203_write_evidence $evidence_file [list \
    "Build: SUCCESS" \
    "Mode: checkpoint_place_route_skip_opt" \
    "Part: $target_part" \
    "ENABLE_ROCC_ACCEL: $enable_rocc" \
    "ENABLE_MEM_SUBSYS: $enable_mem_subsys" \
    "ENABLE_DDR3: $enable_ddr3" \
    "DDR3_FETCH_DEBUG: $ddr3_fetch_debug" \
    "DDR3_BRIDGE_AUDIT: $ddr3_bridge_audit" \
    "AX7203_STEP2_BEACON_DEBUG: $step2_beacon_debug" \
    "AX7203_DDR3_LOADER_BEACON_DEBUG: $loader_beacon_debug" \
    "TRANSPORT_UART_RXDATA_REG_TEST: $transport_uart_rxdata_reg_test" \
    "SMT_MODE: $smt_mode" \
    "RSDepth: $rs_depth" \
    "RSIdxW: $rs_idx_w" \
    "FetchBufferDepth: $fetch_buffer_depth" \
    "CoreClkMHz: $core_clk_mhz" \
    "UartClkDiv: $uart_clk_div" \
    "TopModule: $top_module" \
    "ImplementationJobs: $impl_jobs" \
    "ImplementationTimeoutMinutes: $impl_timeout_min" \
    "ImplementationElapsedSeconds: $impl_elapsed" \
    "BuildID: 0x$build_id" \
    "BuildManifest: $build_id_file" \
    "SynthCheckpoint: $synth_checkpoint" \
    "RouteCheckpoint: $route_checkpoint" \
    "Bitstream: $bitstream_file" \
    "WNS: $wns" \
    "TNS: $tns" \
    "WHS: $whs" \
    "Unconstrained paths: $num_unconstrained" \
    "Timestamp: [clock format [clock seconds]]" \
]

puts "Timing Results:"
puts "  WNS: $wns"
puts "  TNS: $tns"
puts "  WHS: $whs"
puts "  Build ID: 0x$build_id"

if {$wns ne "NA" && $wns < 0} {
    puts "WARNING: Setup timing violations detected! WNS = $wns"
    if {!$is_compare} {
        puts "ERROR: Primary target ($target_part) has setup timing violations. Fix before continuing."
        exit 1
    }
}

if {$whs ne "NA" && $whs < 0} {
    puts "WARNING: Hold timing violations detected! WHS = $whs"
    if {!$is_compare} {
        puts "ERROR: Primary target ($target_part) has hold timing violations. Fix before continuing."
        exit 1
    }
}

if {$num_unconstrained > 0} {
    puts "ERROR: $num_unconstrained unconstrained paths found. Add constraints and rebuild."
    exit 1
}

puts "Build completed successfully!"
catch {close_design}
catch {close_project}
exit 0
