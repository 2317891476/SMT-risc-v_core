open_hw_manager
connect_hw_server
current_hw_target [lindex [get_hw_targets *] 0]
open_hw_target

current_hw_device [lindex [get_hw_devices] 0]
set_property PROGRAM.FILE {./build/top.bit} [current_hw_device]
program_hw_devices [current_hw_device]
refresh_hw_device [current_hw_device]

puts "Program done. Device: [current_hw_device]"
exit