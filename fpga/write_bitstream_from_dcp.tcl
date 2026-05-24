# write_bitstream_from_dcp.tcl
# Write a diagnostic bitstream from an existing routed checkpoint.

set script_dir [file dirname [info script]]
source "$script_dir/flow_common.tcl"

set project_dir [file normalize [ax7203_env_or_default PROJECT_DIR "$script_dir/../build/ax7203"]]
set target_part [ax7203_env_or_default TARGET_PART "xc7a200tfbg484-2"]
set default_dcp "$project_dir/checkpoints/sifang_core_ax7203_incremental_route.dcp"
set routed_dcp [file normalize [ax7203_env_or_default ROUTED_DCP $default_dcp]]
set bitstream_file [file normalize [ax7203_env_or_default BITSTREAM_FILE "$project_dir/sifang_core_ax7203_diagnostic_${target_part}.bit"]]
set build_id_file [file normalize [ax7203_env_or_default BUILD_ID_FILE "$project_dir/sifang_core_ax7203_diagnostic_bitstream_id.txt"]]
set timing_report [file normalize [ax7203_env_or_default TIMING_REPORT "$project_dir/reports/timing_summary_diagnostic_from_dcp.rpt"]]
set route_report [file normalize [ax7203_env_or_default ROUTE_REPORT "$project_dir/reports/route_status_diagnostic_from_dcp.rpt"]]

if {![file exists $routed_dcp]} {
    puts "ERROR: Routed checkpoint not found: $routed_dcp"
    exit 1
}

file mkdir [file dirname $bitstream_file]
file mkdir [file dirname $build_id_file]
file mkdir [file dirname $timing_report]
file mkdir [file dirname $route_report]

puts "Opening routed checkpoint: $routed_dcp"
open_checkpoint $routed_dcp

set build_id [format %08X [expr {[clock seconds] & 0xFFFFFFFF}]]
set_property BITSTREAM.CONFIG.USERID "32'h$build_id" [current_design]
set_property BITSTREAM.CONFIG.USR_ACCESS "0x$build_id" [current_design]

report_route_status -file $route_report
report_timing_summary -file $timing_report -max_paths 10

puts "Writing diagnostic bitstream: $bitstream_file"
write_bitstream -force $bitstream_file

ax7203_write_evidence $build_id_file [list \
    "BUILD_ID=0x$build_id" \
    "TOP_MODULE=[get_property top [current_design]]" \
    "BITSTREAM=$bitstream_file" \
    "ROUTED_DCP=$routed_dcp" \
    "TARGET_PART=$target_part" \
    "TIMING_REPORT=$timing_report" \
    "ROUTE_REPORT=$route_report" \
    "TIMESTAMP=[clock format [clock seconds]]" \
]

puts "Diagnostic build ID: 0x$build_id"
puts "Build manifest: $build_id_file"
catch {close_design}
exit 0
