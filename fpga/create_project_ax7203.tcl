# create_project_ax7203.tcl
# Create Vivado project for ALINX AX7203
# Usage: vivado -mode batch -source fpga/create_project_ax7203.tcl

set script_dir [file dirname [info script]]
set project_name "adam_riscv_ax7203"
set project_dir "$script_dir/../build/ax7203"
set rtl_dir "$script_dir/../rtl"
set fpga_rtl_dir "$script_dir/rtl"
set ram_bfm_file "$script_dir/../libs/REG_ARRAY/SRAM/ram_bfm.v"
set bram_init_dir "$script_dir/bram_init"
set coe_gen_py "$script_dir/scripts/generate_coe.py"
set inst_hex "$script_dir/../rom/inst.hex"
set data_hex "$script_dir/../rom/data.hex"
set inst_coe "$bram_init_dir/inst_mem.coe"
set data_coe "$bram_init_dir/data_mem.coe"

# Parse arguments for part selection
set target_part "xc7a200tfbg484-2"
if {[info exists ::env(TARGET_PART)]} {
    set target_part $::env(TARGET_PART)
}

puts "Creating project: $project_name"
puts "Target part: $target_part"
puts "Project directory: $project_dir"

# Create project
create_project -force $project_name $project_dir -part $target_part

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

# Generate Clock Wizard IP (required by adam_riscv when FPGA_MODE is defined)
set clk_wiz_tcl "$script_dir/ip/create_clk_wiz_ax7203.tcl"
if {[file exists $clk_wiz_tcl]} {
    puts "Generating Clock Wizard IP from: $clk_wiz_tcl"
    # Source in a way that doesn't conflict with our variables
    set ::env(TARGET_PART) $target_part
    source $clk_wiz_tcl
} else {
    puts "WARNING: Missing Clock Wizard IP script: $clk_wiz_tcl"
    puts "WARNING: The core requires clk_wiz_0 when FPGA_MODE is defined."
}

# Generate BRAM IP after RTL sources are added
set bram_ip_tcl "$bram_init_dir/create_bram_ip.tcl"
if {[file exists $bram_ip_tcl]} {
    puts "Generating BRAM IP from: $bram_ip_tcl"
    source $bram_ip_tcl
} else {
    puts "ERROR: Missing BRAM IP script: $bram_ip_tcl"
    exit 1
}

# Set top module
set_property top adam_riscv_ax7203_top [get_filesets sources_1]

# Define FPGA_MODE for core (required for clk_wiz_0 and led port)
set_property verilog_define FPGA_MODE=1 [get_filesets sources_1]

# Add constraints
set constraints_dir "$script_dir/constraints"
if {[file exists $constraints_dir/ax7203_base.xdc]} {
    add_files -fileset constrs_1 $constraints_dir/ax7203_base.xdc
}
if {[file exists $constraints_dir/ax7203_uart_led.xdc]} {
    add_files -fileset constrs_1 $constraints_dir/ax7203_uart_led.xdc
}

# Create directories
file mkdir $project_dir/logs
file mkdir $project_dir/reports
file mkdir $project_dir/checkpoints

puts "Project created successfully!"
puts "Part: $target_part"
puts "To build: vivado -mode batch -source fpga/build_ax7203_bitstream.tcl"

# Save evidence
set evidence_file "$script_dir/../.sisyphus/evidence/task-2-create-project.log"
file mkdir [file dirname $evidence_file]
set fh [open $evidence_file w]
puts $fh "Project creation: SUCCESS"
puts $fh "Part: $target_part"
puts $fh "Timestamp: [clock format [clock seconds]]"
close $fh

exit 0
