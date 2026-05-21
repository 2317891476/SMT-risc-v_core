# synth_ooc_module.tcl
# Fast out-of-context synthesis for local RTL debug.
# Usage:
#   vivado.bat -mode batch -source fpga/synth_ooc_module.tcl -tclargs OOC_TOP=ddr3_mem_port

set script_dir [file dirname [info script]]
source "$script_dir/flow_common.tcl"

proc ooc_arg_or_env {name default_value} {
    global argv
    set argc [llength $argv]
    for {set i 0} {$i < $argc} {incr i} {
        set arg [lindex $argv $i]
        if {[regexp "^${name}=(.*)$" $arg -> value]} {
            return $value
        }
        if {$arg eq $name && [expr {$i + 1}] < $argc} {
            return [lindex $argv [expr {$i + 1}]]
        }
    }
    return [ax7203_env_or_default $name $default_value]
}

proc ooc_split_list {value} {
    set normalized [string map {"," " " ";" " "} $value]
    set result {}
    foreach item $normalized {
        if {$item ne ""} {
            lappend result $item
        }
    }
    return $result
}

proc ooc_normalize_files {repo_root file_list} {
    set result {}
    foreach file_name $file_list {
        if {[file pathtype $file_name] eq "absolute"} {
            set path [file normalize $file_name]
        } else {
            set path [file normalize "$repo_root/$file_name"]
        }
        if {![file exists $path]} {
            puts "ERROR: OOC source file not found: $path"
            exit 1
        }
        lappend result $path
    }
    return $result
}

set repo_root [file normalize "$script_dir/.."]
set ooc_top [ooc_arg_or_env OOC_TOP ""]
set target_part [ooc_arg_or_env OOC_PART [ax7203_env_or_default TARGET_PART "xc7a200tfbg484-2"]]
set ooc_files_arg [ooc_arg_or_env OOC_FILES ""]
set ooc_defines_arg [ooc_arg_or_env OOC_DEFINES ""]

if {$ooc_top eq ""} {
    puts "ERROR: OOC_TOP is required. Example: -tclargs OOC_TOP=ddr3_mem_port"
    exit 1
}

if {$ooc_files_arg ne ""} {
    set ooc_files [ooc_normalize_files $repo_root [ooc_split_list $ooc_files_arg]]
} else {
    switch -- $ooc_top {
        "ddr3_mem_port" {
            set ooc_files [ooc_normalize_files $repo_root [list rtl/ddr3_mem_port.v]]
        }
        "plic" {
            set ooc_files [ooc_normalize_files $repo_root [list rtl/plic.v]]
        }
        "mem_subsys" {
            set ooc_files [ooc_normalize_files $repo_root [list \
                rtl/mem_subsys.v \
                rtl/l1_dcache_m1.v \
                rtl/l2_arbiter.v \
                rtl/l2_cache.v \
                rtl/clint.v \
                rtl/plic.v \
                rtl/uart_tx.v \
                rtl/uart_rx.v \
                rtl/debug_beacon_tx.v \
            ]]
        }
        default {
            set candidate "$repo_root/rtl/${ooc_top}.v"
            if {[file exists $candidate]} {
                set ooc_files [list [file normalize $candidate]]
            } else {
                set ooc_files [glob -nocomplain -directory "$repo_root/rtl" *.v]
            }
        }
    }
}

set ooc_defines [ooc_split_list $ooc_defines_arg]
if {$ooc_top eq "mem_subsys" && [llength $ooc_defines] == 0} {
    set ooc_defines [list \
        FPGA_MODE=1 \
        ENABLE_MEM_SUBSYS=1 \
        ENABLE_DDR3=1 \
        L2_PASSTHROUGH=1 \
        SMT_MODE=0 \
        FPGA_SCOREBOARD_RS_DEPTH=48 \
        FPGA_SCOREBOARD_RS_IDX_W=6 \
        FPGA_FETCH_BUFFER_DEPTH=16 \
        FPGA_UART_CLK_DIV=217 \
    ]
}

set out_dir [file normalize "$repo_root/build/ooc/$ooc_top"]
set report_dir "$out_dir/reports"
set saved_pwd [pwd]
file mkdir $report_dir

puts "=== AX7203 OOC synthesis ==="
puts "Top: $ooc_top"
puts "Part: $target_part"
puts "Output: $out_dir"
puts "Defines: $ooc_defines"
puts "Files:"
foreach file_name $ooc_files {
    puts "  $file_name"
}

read_verilog -sv $ooc_files
set_property include_dirs [list "$repo_root/rtl" "$repo_root/fpga/rtl"] [current_fileset]
if {[llength $ooc_defines] > 0} {
    set_property verilog_define $ooc_defines [current_fileset]
}
if {$ooc_top eq "mem_subsys" && [file exists "$repo_root/rom/mem_subsys_ram.hex"]} {
    cd "$repo_root/rom"
}

set synth_args [list \
    -top $ooc_top \
    -part $target_part \
    -mode out_of_context \
    -flatten_hierarchy none \
    -directive RuntimeOptimized \
]

synth_design {*}$synth_args
write_checkpoint -force "$out_dir/post_synth.dcp"
report_utilization -file "$report_dir/utilization.rpt"
report_utilization -hierarchical -hierarchical_depth 3 -file "$report_dir/utilization_hier.rpt"
report_timing_summary -file "$report_dir/timing_summary.rpt" -max_paths 10

puts "OOC synthesis completed."
puts "Checkpoint: $out_dir/post_synth.dcp"
puts "Reports: $report_dir"

cd $saved_pwd
catch {close_design}
exit 0
