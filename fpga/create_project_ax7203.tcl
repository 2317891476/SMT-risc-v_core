# create_project_ax7203.tcl
# Create Vivado project for ALINX AX7203
# Usage: vivado -mode batch -source fpga/create_project_ax7203.tcl

set script_dir [file dirname [info script]]
source "$script_dir/flow_common.tcl"

set project_name "adam_riscv_ax7203"
set project_dir [file normalize [ax7203_env_or_default PROJECT_DIR "$script_dir/../build/ax7203"]]
set rtl_dir "$script_dir/../rtl"
set fpga_rtl_dir "$script_dir/rtl"
set ram_bfm_file "$script_dir/../libs/REG_ARRAY/SRAM/ram_bfm.v"
set bram_init_dir "$script_dir/bram_init"
set coe_gen_py "$script_dir/scripts/generate_coe.py"
set inst_hex "$script_dir/../rom/inst.hex"
set data_hex "$script_dir/../rom/data.hex"
set inst_coe "$bram_init_dir/inst_mem.coe"
set data_coe "$bram_init_dir/data_mem.coe"

# Parse build configuration
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
set rs_depth [expr {[ax7203_env_or_default AX7203_RS_DEPTH 16] + 0}]
set fetch_buffer_depth [expr {[ax7203_env_or_default AX7203_FETCH_BUFFER_DEPTH 16] + 0}]
set rs_idx_w [expr {[ax7203_env_or_default AX7203_RS_IDX_W [ax7203_clog2 $rs_depth]] + 0}]
set core_clk_mhz [expr {double([ax7203_env_or_default AX7203_CORE_CLK_MHZ 25.0])}]
set uart_clk_div [expr {[ax7203_env_or_default AX7203_UART_CLK_DIV [ax7203_uart_clk_div $core_clk_mhz]] + 0}]
set build_threads [ax7203_env_or_default AX7203_MAX_THREADS 4]
set top_module [ax7203_env_or_default AX7203_TOP_MODULE "adam_riscv_ax7203_top"]

puts "Creating project: $project_name"
puts "Target part: $target_part"
puts "Project directory: $project_dir"
puts "AX7203_ENABLE_ROCC: $enable_rocc"
puts "AX7203_ENABLE_MEM_SUBSYS: $enable_mem_subsys"
puts "AX7203_ENABLE_DDR3: $enable_ddr3"
puts "AX7203_DDR3_FETCH_DEBUG: $ddr3_fetch_debug"
puts "AX7203_DDR3_BRIDGE_AUDIT: $ddr3_bridge_audit"
puts "AX7203_STEP2_BEACON_DEBUG: $step2_beacon_debug"
puts "AX7203_DDR3_LOADER_BEACON_DEBUG: $loader_beacon_debug"
puts "AX7203_TRANSPORT_UART_RXDATA_REG_TEST: $transport_uart_rxdata_reg_test"
puts "AX7203_SMT_MODE: $smt_mode"
puts "AX7203_RS_DEPTH: $rs_depth"
puts "AX7203_RS_IDX_W: $rs_idx_w"
puts "AX7203_FETCH_BUFFER_DEPTH: $fetch_buffer_depth"
puts "AX7203_CORE_CLK_MHZ: $core_clk_mhz"
puts "AX7203_UART_CLK_DIV: $uart_clk_div"
puts "AX7203_MAX_THREADS: $build_threads"
puts "AX7203_TOP_MODULE: $top_module"

puts "Preparing board ROM image..."
ax7203_build_board_rom $script_dir

# When using mem_subsys, regenerate the combined hex from inst.hex + data.hex.
if {$enable_mem_subsys} {
    set merge_py "$script_dir/scripts/merge_hex_for_mem_subsys.py"
    if {[file exists $merge_py]} {
        foreach launcher [list [list py -3] [list python] [list python3]] {
            set resolved [auto_execok [lindex $launcher 0]]
            if {$resolved ne ""} {
                if {![catch {exec {*}$launcher $merge_py} merge_out]} {
                    puts "INFO: $merge_out"
                    break
                }
            }
        }
    }
}

# Create project
create_project -force $project_name $project_dir -part $target_part
set_param general.maxThreads $build_threads

# Set project properties
set_property board_part "" [current_project]
set_property target_language Verilog [current_project]
set_property default_lib work [current_project]
set_property simulator_language Mixed [current_project]
set_property coreContainer.enable 0 [current_project]

# Add RTL source files
puts "Adding RTL sources..."

proc collect_verilog_files {root_dir} {
    set result [glob -nocomplain -directory $root_dir *.v]
    foreach path [glob -nocomplain -directory $root_dir *] {
        if {[file isdirectory $path]} {
            set nested [collect_verilog_files $path]
            if {[llength $nested] > 0} {
                set result [concat $result $nested]
            }
        }
    }
    return $result
}

# Core RTL
set core_rtl_files [collect_verilog_files $rtl_dir]
if {[llength $core_rtl_files] == 0} {
    puts "ERROR: No core RTL files found under $rtl_dir"
    exit 1
}
add_files $core_rtl_files

# Shared library models required by the core RTL
if {![file exists $ram_bfm_file]} {
    puts "ERROR: Missing shared library model: $ram_bfm_file"
    exit 1
}
add_files -norecurse $ram_bfm_file

# FPGA-specific RTL (to be created)
if {[file exists $fpga_rtl_dir]} {
    set fpga_rtl_files [collect_verilog_files $fpga_rtl_dir]
    if {[llength $fpga_rtl_files] > 0} {
        add_files $fpga_rtl_files
    }
}

# Generate COE files for BRAM init (standalone script)
if {[file exists $coe_gen_py]} {
    set force_coe_gen 0
    if {[info exists ::env(FORCE_COE_GEN)]} {
        set force_coe_gen $::env(FORCE_COE_GEN)
    }

    set have_existing_coe 0
    if {[file exists $inst_coe] && [file exists $data_coe]} {
        set have_existing_coe 1
    }

    if {$have_existing_coe && !$force_coe_gen} {
        puts "INFO: Using existing COE files:"
        puts "INFO:   $inst_coe"
        puts "INFO:   $data_coe"
        puts "INFO: Set FORCE_COE_GEN=1 to regenerate from rom/*.hex"
    } else {
        puts "Generating BRAM COE files from rom/inst.hex and rom/data.hex..."
    set coe_depth 8192
    if {[info exists ::env(BRAM_DEPTH)]} {
        set coe_depth $::env(BRAM_DEPTH)
    }

    if {![file exists $inst_hex]} {
        puts "ERROR: Missing instruction hex file: $inst_hex"
        exit 1
    }
    if {![file exists $data_hex]} {
        puts "WARNING: Missing data hex file: $data_hex"
        puts "WARNING: Continuing; data_mem.coe will be generated as zero image if script handles empty input."
    }

    set coe_cmds {}
    if {[info exists ::env(PYTHON_BIN)]} {
        lappend coe_cmds [list $::env(PYTHON_BIN)]
    }
    lappend coe_cmds [list py -3]
    lappend coe_cmds [list python]
    lappend coe_cmds [list python3]

    set coe_ok 0
    set coe_last_err ""
    foreach launcher $coe_cmds {
        set cmd [concat $launcher [list $coe_gen_py --inst-input $inst_hex --data-input $data_hex --inst-output $inst_coe --data-output $data_coe --depth $coe_depth]]
        puts "INFO: Trying COE generator launcher: [join $launcher { }]"
        if {[catch {exec {*}$cmd} coe_out]} {
            set coe_last_err $coe_out
            puts "WARNING: COE launcher failed: [join $launcher { }]"
            continue
        }
        puts $coe_out
        set coe_ok 1
        break
    }

        if {!$coe_ok} {
            if {[file exists $inst_coe] && [file exists $data_coe]} {
                puts "WARNING: COE regeneration failed, using existing COE files."
                puts "WARNING: Last launcher output: $coe_last_err"
            } else {
                puts "ERROR: Failed to generate COE files with all launchers."
                puts "ERROR: Last launcher output: $coe_last_err"
                exit 1
            }
        }
    }
} else {
    puts "ERROR: Missing COE generator script: $coe_gen_py"
    exit 1
}

# Add COE files to project for traceability
if {[file exists $inst_coe]} {
    add_files -norecurse $inst_coe
}
if {[file exists $data_coe]} {
    add_files -norecurse $data_coe
}
if {[file exists $inst_hex]} {
    add_files -norecurse $inst_hex
    set_property file_type {Memory File} [get_files $inst_hex]
}
if {[file exists $data_hex]} {
    add_files -norecurse $data_hex
    set_property file_type {Memory File} [get_files $data_hex]
}
set data_word_hex "$script_dir/../rom/data_word.hex"
if {[file exists $data_word_hex]} {
    add_files -norecurse $data_word_hex
    set_property file_type {Memory File} [get_files $data_word_hex]
}
set mem_subsys_ram_hex "$script_dir/../rom/mem_subsys_ram.hex"
if {[file exists $mem_subsys_ram_hex]} {
    add_files -norecurse $mem_subsys_ram_hex
    set_property file_type {Memory File} [get_files $mem_subsys_ram_hex]
}

# Generate MIG 7-Series DDR3 IP (when DDR3 is enabled)
if {$enable_ddr3} {
    set mig_tcl "$script_dir/ip/create_mig_ax7203.tcl"
    if {[file exists $mig_tcl]} {
        puts "Generating MIG 7-Series DDR3 IP from: $mig_tcl"
        set _saved_script_dir $script_dir
        source $mig_tcl
        set script_dir $_saved_script_dir
    } else {
        puts "ERROR: Missing MIG IP script: $mig_tcl"
        exit 1
    }
}

# Generate Clock Wizard IP (required by adam_riscv when FPGA_MODE is defined)
set clk_wiz_tcl "$script_dir/ip/create_clk_wiz_ax7203.tcl"
if {[file exists $clk_wiz_tcl]} {
    puts "Generating Clock Wizard IP from: $clk_wiz_tcl"
    # Source in a way that doesn't conflict with our variables
    set ::env(TARGET_PART) $target_part
    source $clk_wiz_tcl
    set clk_xci_files [get_files -quiet */clk_wiz_0.xci]
    set clk_generated_files [list \
        "$project_dir/${project_name}.gen/sources_1/ip/clk_wiz_0/clk_wiz_0.v" \
        "$project_dir/${project_name}.gen/sources_1/ip/clk_wiz_0/clk_wiz_0_clk_wiz.v" \
    ]
    foreach clk_generated_file $clk_generated_files {
        if {![file exists $clk_generated_file]} {
            puts "ERROR: Missing generated Clock Wizard HDL: $clk_generated_file"
            exit 1
        }
        add_files -norecurse $clk_generated_file
    }
    if {[llength $clk_xci_files] > 0} {
        puts "INFO: Removing clk_wiz_0.xci after HDL generation to avoid fragile in-run IP regeneration."
        remove_files $clk_xci_files
    }
} else {
    puts "WARNING: Missing Clock Wizard IP script: $clk_wiz_tcl"
    puts "WARNING: The core requires clk_wiz_0 when FPGA_MODE is defined."
}

# Generate BRAM IP after RTL sources are added
set bram_ip_tcl "$bram_init_dir/create_bram_ip.tcl"
if {[file exists $bram_ip_tcl]} {
    puts "Generating BRAM IP from: $bram_ip_tcl"
    source $bram_ip_tcl
    set bram_xci_files [get_files -quiet */bram_mem_0.xci]
    if {[llength $bram_xci_files] > 0} {
        set_property GENERATE_SYNTH_CHECKPOINT 0 $bram_xci_files
    }
} else {
    puts "ERROR: Missing BRAM IP script: $bram_ip_tcl"
    exit 1
}

# Set top module
set_property top $top_module [get_filesets sources_1]

# Define FPGA build knobs explicitly so board synthesis is reproducible.
# When using mem_subsys with on-chip SRAM, bypass the L2 cache arrays
# to avoid 185K-LUT distributed-RAM explosion.  Phase 2 (DDR3) will
# replace this with a BRAM-backed L2.
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

# Keep FPGA bring-up synthesis biased toward runtime so the batch flow can
# stay under the board-validation time budget more reliably.
set_property strategy "Flow_RuntimeOptimized" [get_runs synth_1]
set_property strategy "Vivado Implementation Defaults" [get_runs impl_1]

# Add constraints
set constraints_dir "$script_dir/constraints"
if {[file exists $constraints_dir/ax7203_base.xdc]} {
    add_files -fileset constrs_1 $constraints_dir/ax7203_base.xdc
}
if {[file exists $constraints_dir/ax7203_uart_led.xdc]} {
    add_files -fileset constrs_1 $constraints_dir/ax7203_uart_led.xdc
}
if {$enable_ddr3 && [file exists $constraints_dir/ax7203_ddr3.xdc]} {
    add_files -fileset constrs_1 $constraints_dir/ax7203_ddr3.xdc
}

# Create directories
file mkdir $project_dir/logs
file mkdir $project_dir/reports
file mkdir $project_dir/checkpoints

puts "Project created successfully!"
puts "Part: $target_part"
puts "Top: $top_module"
puts "Defines: FPGA_MODE=1 ENABLE_ROCC_ACCEL=$enable_rocc ENABLE_MEM_SUBSYS=$enable_mem_subsys ENABLE_DDR3=$enable_ddr3 DDR3_FETCH_DEBUG=$ddr3_fetch_debug DDR3_BRIDGE_AUDIT=$ddr3_bridge_audit AX7203_STEP2_BEACON_DEBUG=$step2_beacon_debug AX7203_DDR3_LOADER_BEACON_DEBUG=$loader_beacon_debug TRANSPORT_UART_RXDATA_REG_TEST=$transport_uart_rxdata_reg_test SMT_MODE=$smt_mode FPGA_SCOREBOARD_RS_DEPTH=$rs_depth FPGA_SCOREBOARD_RS_IDX_W=$rs_idx_w FPGA_FETCH_BUFFER_DEPTH=$fetch_buffer_depth"
puts "To build: vivado -mode batch -source fpga/build_ax7203_bitstream.tcl"

# Save evidence
set evidence_file "$script_dir/../.sisyphus/evidence/task-2-create-project.log"
ax7203_write_evidence $evidence_file [list \
    "Project creation: SUCCESS" \
    "Part: $target_part" \
    "Project directory: $project_dir" \
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
    "TopModule: $top_module" \
    "MaxThreads: $build_threads" \
    "Timestamp: [clock format [clock seconds]]" \
]

exit 0
