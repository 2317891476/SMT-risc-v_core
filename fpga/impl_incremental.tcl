# impl_incremental.tcl
# Incremental implementation from the latest AX7203 synthesized checkpoint.
# Usage:
#   vivado.bat -mode batch -source fpga/impl_incremental.tcl

set script_dir [file dirname [info script]]
source "$script_dir/flow_common.tcl"

proc ax7203_parse_incremental_reuse_pct {path} {
    if {![file exists $path]} {
        return -1.0
    }
    set fh [open $path r]
    set text [read $fh]
    close $fh
    set best -1.0
    foreach line [split $text "\n"] {
        set lower [string tolower $line]
        if {[string first "reuse" $lower] >= 0 && [regexp {([0-9]+(\.[0-9]+)?)\s*%} $line -> pct]} {
            set pct_value [expr {double($pct)}]
            if {$pct_value > $best} {
                set best $pct_value
            }
        }
    }
    return $best
}

proc ax7203_parse_incremental_cell_reuse_pct {path} {
    if {![file exists $path]} {
        return -1.0
    }
    set fh [open $path r]
    set text [read $fh]
    close $fh
    foreach line [split $text "\n"] {
        if {[regexp {^\|\s*Cells\s*\|\s*([0-9]+(\.[0-9]+)?)\s*\|\s*([0-9]+(\.[0-9]+)?)\s*\|} $line -> matched _ current]} {
            return [expr {double($current)}]
        }
    }
    return -1.0
}

set project_dir [file normalize [ax7203_env_or_default PROJECT_DIR "$script_dir/../build/ax7203"]]
set project_name "adam_riscv_ax7203"
set target_part [ax7203_env_or_default TARGET_PART "xc7a200tfbg484-2"]
set top_module [ax7203_env_or_default AX7203_TOP_MODULE "adam_riscv_ax7203_top"]
set impl_jobs [ax7203_vivado_jobs AX7203_IMPL_JOBS]
set enable_mem_subsys [ax7203_env_or_default AX7203_ENABLE_MEM_SUBSYS 1]
set enable_ddr3 [ax7203_env_or_default AX7203_ENABLE_DDR3 1]
set smt_mode [ax7203_env_or_default AX7203_SMT_MODE 0]
set rs_depth [expr {[ax7203_env_or_default AX7203_RS_DEPTH 48] + 0}]
set fetch_buffer_depth [expr {[ax7203_env_or_default AX7203_FETCH_BUFFER_DEPTH 16] + 0}]
set rs_idx_w [expr {[ax7203_env_or_default AX7203_RS_IDX_W [ax7203_clog2 $rs_depth]] + 0}]
set core_clk_mhz [expr {double([ax7203_env_or_default AX7203_CORE_CLK_MHZ 25.0])}]
set uart_clk_div [expr {[ax7203_env_or_default AX7203_UART_CLK_DIV [ax7203_uart_clk_div $core_clk_mhz]] + 0}]
set min_reuse_pct [expr {double([ax7203_env_or_default AX7203_INCREMENTAL_MIN_CELL_REUSE_PCT 80.0])}]
set update_reference_checkpoint [expr {[ax7203_env_or_default AX7203_INCREMENTAL_UPDATE_REFERENCE 0] ? 1 : 0}]
set skip_post_route_physopt [expr {[ax7203_env_or_default AX7203_INCREMENTAL_SKIP_POST_ROUTE_PHYSOPT 0] ? 1 : 0}]
set incremental_directive [ax7203_env_or_default AX7203_INCREMENTAL_DIRECTIVE "RuntimeOptimized"]
set place_directive [ax7203_env_or_default AX7203_INCREMENTAL_PLACE_DIRECTIVE "Quick"]
set physopt_directive [ax7203_env_or_default AX7203_INCREMENTAL_PHYSOPT_DIRECTIVE "Explore"]
set route_directive [ax7203_env_or_default AX7203_INCREMENTAL_ROUTE_DIRECTIVE "Quick"]

set report_dir "$project_dir/reports"
set checkpoint_dir "$project_dir/checkpoints"
set synth_checkpoint "$checkpoint_dir/${project_name}_post_synth.dcp"
if {$top_module eq "adam_riscv_ax7203_top"} {
    set route_checkpoint "$checkpoint_dir/${project_name}_post_route.dcp"
    set incremental_route_checkpoint "$checkpoint_dir/${project_name}_incremental_route.dcp"
    set reference_checkpoint [file normalize [ax7203_env_or_default AX7203_INCREMENTAL_REF_DCP $route_checkpoint]]
    set bitstream_file "$project_dir/${project_name}_${target_part}.bit"
    set build_id_file "$project_dir/${project_name}_bitstream_id.txt"
} else {
    set route_checkpoint "$checkpoint_dir/${project_name}_${top_module}_post_route.dcp"
    set incremental_route_checkpoint "$checkpoint_dir/${project_name}_${top_module}_incremental_route.dcp"
    set reference_checkpoint [file normalize [ax7203_env_or_default AX7203_INCREMENTAL_REF_DCP $route_checkpoint]]
    set bitstream_file "$project_dir/${project_name}_${top_module}_${target_part}.bit"
    set build_id_file "$project_dir/${project_name}_${top_module}_bitstream_id.txt"
}

set base_xdc "$script_dir/constraints/ax7203_base.xdc"
set uart_led_xdc "$script_dir/constraints/ax7203_uart_led.xdc"
set ddr3_xdc "$script_dir/constraints/ax7203_ddr3.xdc"
set clk_wiz_board_xdc "$project_dir/${project_name}.gen/sources_1/ip/clk_wiz_0/clk_wiz_0_board.xdc"
set clk_wiz_timing_xdc "$project_dir/${project_name}.gen/sources_1/ip/clk_wiz_0/clk_wiz_0.xdc"

if {![file exists $synth_checkpoint]} {
    puts "ERROR: Synth checkpoint not found: $synth_checkpoint"
    puts "Run synthesis first: vivado.bat -mode batch -source fpga/run_ax7203_synth.tcl"
    exit 1
}
if {![file exists $reference_checkpoint]} {
    puts "ERROR: Incremental reference checkpoint not found: $reference_checkpoint"
    puts "Run full implementation first or set AX7203_INCREMENTAL_REF_DCP to a routed checkpoint."
    exit 1
}

file mkdir $report_dir
file mkdir $checkpoint_dir
ax7203_apply_vivado_threads $impl_jobs

puts "=== Incremental Implementation ==="
puts "Top module: $top_module"
puts "Synth checkpoint: $synth_checkpoint"
puts "Reference checkpoint: $reference_checkpoint"
puts "Update reference checkpoint on success: $update_reference_checkpoint"
puts "Skip post-route phys_opt_design: $skip_post_route_physopt"
puts "Implementation jobs: $impl_jobs"
puts "Minimum parsed reuse threshold: ${min_reuse_pct}%"
puts "Incremental directive: $incremental_directive"
puts "Place directive: $place_directive"
puts "Physopt directive: $physopt_directive"
puts "Route directive: $route_directive"
puts "ENABLE_MEM_SUBSYS: $enable_mem_subsys"
puts "ENABLE_DDR3: $enable_ddr3"
puts "SMT_MODE: $smt_mode"
puts "RS depth: $rs_depth"
puts "Fetch buffer depth: $fetch_buffer_depth"
puts "Core clock: ${core_clk_mhz} MHz"
puts "UART clock divider: $uart_clk_div"

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

puts "Phase 1: opt_design -directive Explore"
opt_design -directive Explore

puts "Phase 2: read_checkpoint -directive $incremental_directive -incremental"
read_checkpoint -directive $incremental_directive -incremental $reference_checkpoint

set incremental_reuse_preplace "$report_dir/incremental_reuse_preplace.rpt"
catch {report_incremental_reuse -file $incremental_reuse_preplace}
set preplace_cell_reuse_pct [ax7203_parse_incremental_cell_reuse_pct $incremental_reuse_preplace]
if {$preplace_cell_reuse_pct >= 0 && $preplace_cell_reuse_pct < $min_reuse_pct} {
    puts "ERROR: Incremental cell reuse ${preplace_cell_reuse_pct}% is below threshold ${min_reuse_pct}% before placement."
    puts "Next step: follow the Dhrystone debug loop; do not auto-run aggressive implementation."
    catch {close_design}
    exit 1
}

set incremental_reuse_place "$report_dir/incremental_reuse_place.rpt"
puts "Phase 3: place_design -directive $place_directive"
if {[catch {place_design -directive $place_directive} place_err]} {
    puts "ERROR: Incremental place_design failed: $place_err"
    puts "Next step: follow the Dhrystone debug loop; do not auto-run aggressive implementation."
    catch {report_incremental_reuse -file $incremental_reuse_place}
    catch {write_checkpoint -force "$checkpoint_dir/${project_name}_incremental_place_failed.dcp"}
    catch {close_design}
    exit 1
}
catch {report_incremental_reuse -file $incremental_reuse_place}

puts "Phase 4: phys_opt_design -directive $physopt_directive"
phys_opt_design -directive $physopt_directive

set incremental_reuse_route "$report_dir/incremental_reuse_route.rpt"
puts "Phase 5: route_design -directive $route_directive"
if {[catch {route_design -directive $route_directive} route_err]} {
    puts "ERROR: Incremental route_design failed: $route_err"
    puts "Next step: follow the Dhrystone debug loop; do not auto-run aggressive implementation."
    catch {report_incremental_reuse -file $incremental_reuse_route}
    catch {write_checkpoint -force "$checkpoint_dir/${project_name}_incremental_route_failed.dcp"}
    catch {close_design}
    exit 1
}
catch {report_incremental_reuse -file $incremental_reuse_route}

if {$skip_post_route_physopt} {
    puts "Phase 6: post-route phys_opt_design skipped by AX7203_INCREMENTAL_SKIP_POST_ROUTE_PHYSOPT"
} else {
    puts "Phase 6: post-route phys_opt_design"
    phys_opt_design
}

set final_unrouted_nets [get_nets -hier -quiet -filter {ROUTE_STATUS == "UNROUTED"}]
if {[llength $final_unrouted_nets] > 0} {
    puts "Repairing [llength $final_unrouted_nets] unrouted net(s)"
    route_design -nets $final_unrouted_nets
    phys_opt_design
}

set reuse_pct [ax7203_parse_incremental_reuse_pct $incremental_reuse_route]
if {$reuse_pct < 0} {
    set reuse_pct [ax7203_parse_incremental_reuse_pct $incremental_reuse_place]
}
if {$reuse_pct >= 0 && $reuse_pct < $min_reuse_pct} {
    puts "ERROR: Incremental reuse ${reuse_pct}% is below threshold ${min_reuse_pct}%."
    puts "Next step: follow the Dhrystone debug loop; do not auto-run aggressive implementation."
    write_checkpoint -force $incremental_route_checkpoint
    exit 1
}

report_route_status -file "$report_dir/route_status_incremental.rpt"
report_timing_summary -file "$report_dir/timing_summary_incremental.rpt" -max_paths 10
report_timing -file "$report_dir/timing_detail_incremental.rpt" -max_paths 20
report_utilization -file "$report_dir/utilization_incremental.rpt"

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
set final_unrouted_nets [get_nets -hier -quiet -filter {ROUTE_STATUS == "UNROUTED"}]

puts "=== Incremental Implementation Results ==="
puts "  WNS: $wns"
puts "  WHS: $whs"
puts "  Parsed reuse: $reuse_pct"
puts "  Build ID: 0x$build_id"
puts "  Unrouted nets after repair: [llength $final_unrouted_nets]"

set impl_status "FAILED_TIMING"
if {[llength $final_unrouted_nets] > 0} {
    puts "ROUTE NOT CLEAN. Saving checkpoint for analysis."
    write_checkpoint -force $incremental_route_checkpoint
} elseif {$wns ne "NA" && $wns >= 0} {
    puts "TIMING MET! Writing checkpoint and bitstream..."
    write_checkpoint -force $incremental_route_checkpoint
    if {$update_reference_checkpoint} {
        write_checkpoint -force $route_checkpoint
    }
    write_bitstream -force $bitstream_file
    ax7203_write_evidence $build_id_file [list \
        "BUILD_ID=0x$build_id" \
        "TOP_MODULE=$top_module" \
        "BITSTREAM=$bitstream_file" \
        "TARGET_PART=$target_part" \
        "TIMESTAMP=[clock format [clock seconds]]" \
    ]
    set impl_status "SUCCESS"
    puts "Bitstream: $bitstream_file"
    puts "Build completed successfully!"
} else {
    puts "TIMING NOT MET. WNS=$wns. Saving checkpoint for analysis."
    puts "Next step: follow the Dhrystone debug loop; do not auto-run aggressive implementation."
    write_checkpoint -force $incremental_route_checkpoint
}

set evidence_file "$script_dir/../.sisyphus/evidence/task-2c-impl-incremental.log"
ax7203_write_evidence $evidence_file [list \
    "IncrementalImplementation: $impl_status" \
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
    "SynthCheckpoint: $synth_checkpoint" \
    "ReferenceCheckpoint: $reference_checkpoint" \
    "IncrementalRouteCheckpoint: $incremental_route_checkpoint" \
    "UpdateReferenceCheckpoint: $update_reference_checkpoint" \
    "SkipPostRoutePhysOpt: $skip_post_route_physopt" \
    "IncrementalDirective: $incremental_directive" \
    "PlaceDirective: $place_directive" \
    "PhysOptDirective: $physopt_directive" \
    "RouteDirective: $route_directive" \
    "ParsedReusePct: $reuse_pct" \
    "MinimumReusePct: $min_reuse_pct" \
    "WNS: $wns" \
    "WHS: $whs" \
    "TimingSummaryIncremental: $report_dir/timing_summary_incremental.rpt" \
    "TimingDetailIncremental: $report_dir/timing_detail_incremental.rpt" \
    "RouteStatusIncremental: $report_dir/route_status_incremental.rpt" \
    "UtilizationIncremental: $report_dir/utilization_incremental.rpt" \
    "Bitstream: $bitstream_file" \
    "BuildManifest: $build_id_file" \
    "BuildID: 0x$build_id" \
    "Timestamp: [clock format [clock seconds]]" \
]

catch {close_design}
if {$impl_status ne "SUCCESS"} {
    exit 1
}
exit 0
