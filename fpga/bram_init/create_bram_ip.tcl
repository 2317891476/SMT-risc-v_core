# create_bram_ip.tcl
# Create BRAM IP for AX7203 BRAM-first milestone.
#
# Usage (standalone):
#   vivado -mode batch -source fpga/bram_init/create_bram_ip.tcl
#
# Usage (from existing project flow):
#   source fpga/bram_init/create_bram_ip.tcl

set bram_script_dir [file dirname [file normalize [info script]]]
set bram_repo_root [file normalize [file join $bram_script_dir ".." ".."]]

set bram_project_name "adam_riscv_ax7203_bram_ip"
set bram_project_dir [file normalize [file join $bram_repo_root "build" "ax7203_bram_ip"]]

set bram_target_part "xc7a200t-2fbg484i"
if {[info exists ::env(TARGET_PART)]} {
    set bram_target_part $::env(TARGET_PART)
}

set bram_depth_words 8192
if {[info exists ::env(BRAM_DEPTH)]} {
    set bram_depth_words $::env(BRAM_DEPTH)
}
if {$bram_depth_words != 8192 && $bram_depth_words != 16384} {
    puts "ERROR: BRAM_DEPTH must be 8192 (32KB) or 16384 (64KB), got: $bram_depth_words"
    return -code error
}

set bram_inst_coe [file normalize [file join $bram_script_dir "inst_mem.coe"]]
set bram_data_coe [file normalize [file join $bram_script_dir "data_mem.coe"]]

if {![file exists $bram_inst_coe]} {
    puts "ERROR: Missing COE file: $bram_inst_coe"
    puts "ERROR: Generate it first with: python fpga/scripts/generate_coe.py"
    return -code error
}
if {![file exists $bram_data_coe]} {
    puts "WARNING: Optional data COE file not found: $bram_data_coe"
    puts "WARNING: Continuing with inst_mem.coe as BRAM init image."
}

# If no project is open, create a standalone project for IP generation.
set bram_created_local_project 0
set bram_cur_proj [current_project -quiet]
if {$bram_cur_proj eq ""} {
    file mkdir $bram_project_dir
    puts "INFO: No open project detected. Creating standalone IP project."
    create_project -force $bram_project_name $bram_project_dir -part $bram_target_part
    set bram_created_local_project 1
}

set bram_ip_name "bram_mem_0"

# Re-create IP if it already exists to keep script idempotent.
set bram_existing_ips [get_ips -quiet $bram_ip_name]
if {[llength $bram_existing_ips] > 0} {
    puts "INFO: Existing IP '$bram_ip_name' found. Removing before re-creation."
    remove_files [get_files -quiet */$bram_ip_name.xci]
}

puts "INFO: Creating Block Memory Generator IP: $bram_ip_name"
puts "INFO: BRAM depth (words): $bram_depth_words"
puts "INFO: COE init file: $bram_inst_coe"

create_ip -name blk_mem_gen -vendor xilinx.com -library ip -module_name $bram_ip_name

set_property -dict [list \
    CONFIG.Memory_Type {True_Dual_Port_RAM} \
    CONFIG.Enable_32bit_Address {false} \
    CONFIG.Use_Byte_Write_Enable {true} \
    CONFIG.Byte_Size {8} \
    CONFIG.Write_Width_A {32} \
    CONFIG.Read_Width_A {32} \
    CONFIG.Write_Width_B {32} \
    CONFIG.Read_Width_B {32} \
    CONFIG.Write_Depth_A $bram_depth_words \
    CONFIG.Register_PortA_Output_of_Memory_Primitives {false} \
    CONFIG.Register_PortB_Output_of_Memory_Primitives {false} \
    CONFIG.Use_RSTA_Pin {false} \
    CONFIG.Use_RSTB_Pin {false} \
    CONFIG.Operating_Mode_A {READ_FIRST} \
    CONFIG.Operating_Mode_B {WRITE_FIRST} \
    CONFIG.Load_Init_File {true} \
    CONFIG.Coe_File $bram_inst_coe \
] [get_ips $bram_ip_name]

set bram_xci_path [get_files -quiet */$bram_ip_name.xci]
if {[llength $bram_xci_path] == 0} {
    puts "ERROR: Failed to locate generated XCI for $bram_ip_name"
    return -code error
}

generate_target {instantiation_template} $bram_xci_path
generate_target all $bram_xci_path
export_ip_user_files -of_objects $bram_xci_path -no_script -sync -force

puts "INFO: BRAM IP generated successfully."
puts "INFO: XCI: $bram_xci_path"
puts "INFO: Note: data_mem.coe is generated for software/data-image flow;"
puts "INFO:       this first milestone binds inst_mem.coe as unified BRAM init image."

if {$bram_created_local_project} {
    close_project
}
