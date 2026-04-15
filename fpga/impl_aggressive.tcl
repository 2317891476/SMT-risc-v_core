# impl_aggressive.tcl
# Re-implement from synth checkpoint with aggressive directives for timing closure
# Usage: vivado -mode batch -source fpga/impl_aggressive.tcl

set script_dir [file dirname [info script]]
source "$script_dir/flow_common.tcl"

set project_dir [file normalize [ax7203_env_or_default PROJECT_DIR "$script_dir/../build/ax7203"]]
set project_name "adam_riscv_ax7203"
set target_part [ax7203_env_or_default TARGET_PART "xc7a200tfbg484-2"]
set top_module [ax7203_env_or_default AX7203_TOP_MODULE "adam_riscv_ax7203_top"]
set impl_jobs [ax7203_env_or_default AX7203_IMPL_JOBS 4]
set enable_mem_subsys [ax7203_env_or_default AX7203_ENABLE_MEM_SUBSYS 1]
set enable_ddr3 [ax7203_env_or_default AX7203_ENABLE_DDR3 1]
set smt_mode [ax7203_env_or_default AX7203_SMT_MODE 1]
set rs_depth [expr {[ax7203_env_or_default AX7203_RS_DEPTH 16] + 0}]
set fetch_buffer_depth [expr {[ax7203_env_or_default AX7203_FETCH_BUFFER_DEPTH 16] + 0}]
set rs_idx_w [expr {[ax7203_env_or_default AX7203_RS_IDX_W [ax7203_clog2 $rs_depth]] + 0}]
set core_clk_mhz [expr {double([ax7203_env_or_default AX7203_CORE_CLK_MHZ 25.0])}]
set uart_clk_div [expr {[ax7203_env_or_default AX7203_UART_CLK_DIV [ax7203_uart_clk_div $core_clk_mhz]] + 0}]

set report_dir "$project_dir/reports"
set checkpoint_dir "$project_dir/checkpoints"
set synth_checkpoint "$checkpoint_dir/${project_name}_post_synth.dcp"
if {$top_module eq "adam_riscv_ax7203_top"} {
    set route_checkpoint "$checkpoint_dir/${project_name}_post_route.dcp"
    set bitstream_file "$project_dir/${project_name}_${target_part}.bit"
    set build_id_file "$project_dir/${project_name}_bitstream_id.txt"
    set aggressive_route_checkpoint "$checkpoint_dir/${project_name}_aggressive_route.dcp"
} else {
    set route_checkpoint "$checkpoint_dir/${project_name}_${top_module}_post_route.dcp"
    set bitstream_file "$project_dir/${project_name}_${top_module}_${target_part}.bit"
    set build_id_file "$project_dir/${project_name}_${top_module}_bitstream_id.txt"
    set aggressive_route_checkpoint "$checkpoint_dir/${project_name}_${top_module}_aggressive_route.dcp"
}

set base_xdc "$script_dir/constraints/ax7203_base.xdc"
set uart_led_xdc "$script_dir/constraints/ax7203_uart_led.xdc"
set ddr3_xdc "$script_dir/constraints/ax7203_ddr3.xdc"
set clk_wiz_board_xdc "$project_dir/${project_name}.gen/sources_1/ip/clk_wiz_0/clk_wiz_0_board.xdc"
set clk_wiz_timing_xdc "$project_dir/${project_name}.gen/sources_1/ip/clk_wiz_0/clk_wiz_0.xdc"

catch {set_param general.maxThreads $impl_jobs}

puts "Opening synthesized checkpoint: $synth_checkpoint"
open_checkpoint $synth_checkpoint
if {[llength [get_cells -quiet u_adam_riscv/clk2cpu/inst]] > 0} {
    read_xdc -cells {u_adam_riscv/clk2cpu/inst} $clk_wiz_board_xdc
    read_xdc -cells {u_adam_riscv/clk2cpu/inst} $clk_wiz_timing_xdc
}
read_xdc $base_xdc
read_xdc $uart_led_xdc
if {$enable_ddr3 && [file exists $ddr3_xdc]} {
    read_xdc $ddr3_xdc
}

set build_id [format %08X [expr {[clock seconds] & 0xFFFFFFFF}]]
set_property BITSTREAM.CONFIG.USERID "32'h$build_id" [current_design]
set_property BITSTREAM.CONFIG.USR_ACCESS "0x$build_id" [current_design]

puts "=== Aggressive Implementation ==="
puts "Top module: $top_module"
puts "Implementation jobs: $impl_jobs"
puts "ENABLE_MEM_SUBSYS: $enable_mem_subsys"
puts "ENABLE_DDR3: $enable_ddr3"
puts "SMT_MODE: $smt_mode"
puts "RS depth: $rs_depth"
puts "Fetch buffer depth: $fetch_buffer_depth"
puts "Core clock: ${core_clk_mhz} MHz"
puts "UART clock divider: $uart_clk_div"
puts "Phase 1: opt_design -directive Explore"
opt_design -directive Explore

puts "Phase 2: place_design -directive ExtraNetDelay_high"
place_design -directive ExtraNetDelay_high

puts "Phase 3: phys_opt_design -directive AggressiveExplore"
phys_opt_design -directive AggressiveExplore

puts "Phase 4: route_design -directive Explore"
route_design -directive Explore

puts "Phase 5: phys_opt_design (post-route)"
phys_opt_design

set unrouted_nets [get_nets -hier -quiet -filter {ROUTE_STATUS == "UNROUTED"}]
if {[llength $unrouted_nets] > 0} {
    puts "Phase 6: repairing [llength $unrouted_nets] unrouted net(s) after post-route phys_opt"
    foreach net_obj $unrouted_nets {
        puts "  Repairing net: $net_obj"
    }
    route_design -nets $unrouted_nets

    puts "Phase 7: post-repair phys_opt_design"
    phys_opt_design
}

report_route_status -file $report_dir/route_status_aggressive.rpt

report_timing_summary -file $report_dir/timing_summary_aggressive.rpt -max_paths 10
report_timing -file $report_dir/timing_detail_aggressive.rpt -max_paths 20
report_utilization -file $report_dir/utilization_aggressive.rpt

set wns "NA"
set whs "NA"
set setup_paths [get_timing_paths -delay_type max -max_paths 1 -nworst 1]
if {[llength $setup_paths] > 0} {
    set wns [get_property SLACK [lindex $setup_paths 0]]
}
set hold_paths [get_timing_paths -delay_type min -max_paths 1 -nworst 1]
if {[llength $hold_paths] > 0} {
    set whs [get_property SLACK [lindex $hold_paths 0]]
}

puts "=== Aggressive Implementation Results ==="
puts "  WNS: $wns"
puts "  WHS: $whs"
puts "  Build ID: 0x$build_id"

set final_unrouted_nets [get_nets -hier -quiet -filter {ROUTE_STATUS == "UNROUTED"}]
puts "  Unrouted nets after repair: [llength $final_unrouted_nets]"

set impl_status "FAILED_TIMING"
set final_route_checkpoint $aggressive_route_checkpoint
if {[llength $final_unrouted_nets] > 0} {
    puts "ROUTE NOT CLEAN. Saving checkpoint for analysis."
    write_checkpoint -force $aggressive_route_checkpoint
} elseif {$wns ne "NA" && $wns >= 0} {
    puts "TIMING MET! Writing checkpoint and bitstream..."
    write_checkpoint -force $route_checkpoint
    write_bitstream -force $bitstream_file
    ax7203_write_evidence $build_id_file [list \
        "BUILD_ID=0x$build_id" \
        "TOP_MODULE=$top_module" \
        "BITSTREAM=$bitstream_file" \
        "TARGET_PART=$target_part" \
        "TIMESTAMP=[clock format [clock seconds]]" \
    ]
    set impl_status "SUCCESS"
    set final_route_checkpoint $route_checkpoint
    puts "Bitstream: $bitstream_file"
    puts "Build completed successfully!"
} else {
    puts "TIMING NOT MET. WNS=$wns. Saving checkpoint for analysis."
    write_checkpoint -force $aggressive_route_checkpoint
}

set evidence_file "$script_dir/../.sisyphus/evidence/task-2c-impl-aggressive.log"
ax7203_write_evidence $evidence_file [list \
    "AggressiveImplementation: $impl_status" \
    "TopModule: $top_module" \
    "TargetPart: $target_part" \
    "ImplementationJobs: $impl_jobs" \
    "ENABLE_MEM_SUBSYS: $enable_mem_subsys" \
    "ENABLE_DDR3: $enable_ddr3" \
    "SMT_MODE: $smt_mode" \
    "RSDepth: $rs_depth" \
    "RSIdxW: $rs_idx_w" \
    "FetchBufferDepth: $fetch_buffer_depth" \
    "CoreClkMHz: $core_clk_mhz" \
    "UartClkDiv: $uart_clk_div" \
    "WNS: $wns" \
    "WHS: $whs" \
    "TimingSummaryAggressive: $report_dir/timing_summary_aggressive.rpt" \
    "TimingDetailAggressive: $report_dir/timing_detail_aggressive.rpt" \
    "RouteStatusAggressive: $report_dir/route_status_aggressive.rpt" \
    "UtilizationAggressive: $report_dir/utilization_aggressive.rpt" \
    "RouteCheckpoint: $final_route_checkpoint" \
    "Bitstream: $bitstream_file" \
    "BuildManifest: $build_id_file" \
    "BuildID: 0x$build_id" \
    "Timestamp: [clock format [clock seconds]]" \
]

catch {close_design}
exit 0
