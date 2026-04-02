# flow_common.tcl
# Shared helpers for AX7203 Vivado batch flows.

proc ax7203_env_or_default {name default_value} {
    if {[info exists ::env($name)] && $::env($name) ne ""} {
        return $::env($name)
    }
    return $default_value
}

proc ax7203_status_is_complete {status} {
    return [string match "*Complete!*" $status]
}

proc ax7203_status_is_failed {status} {
    set upper_status [string toupper $status]
    return [expr {
        [string match "*FAILED*" $upper_status] ||
        [string match "*ERROR*" $upper_status] ||
        [string match "*CANCELLED*" $upper_status] ||
        [string match "*STOPPED*" $upper_status]
    }]
}

proc ax7203_wait_run_with_timeout {run_name timeout_seconds {poll_ms 5000}} {
    set run_obj [get_runs $run_name]
    if {[llength $run_obj] == 0} {
        error "Run '$run_name' does not exist in the current project."
    }

    set start_time [clock seconds]
    set last_status ""

    while {1} {
        set status [get_property STATUS $run_obj]
        set progress [get_property PROGRESS $run_obj]

        if {$status ne $last_status} {
            puts "INFO: $run_name status = $status (progress: $progress)"
            set last_status $status
        }

        if {[ax7203_status_is_complete $status]} {
            return $status
        }

        if {[ax7203_status_is_failed $status]} {
            error "Run '$run_name' failed with status: $status"
        }

        if {[expr {[clock seconds] - $start_time}] >= $timeout_seconds} {
            catch {stop_runs $run_name}
            error "Run '$run_name' timed out after $timeout_seconds seconds (last status: $status)"
        }

        after $poll_ms
    }
}

proc ax7203_copy_first_match {pattern destination} {
    set matches [glob -nocomplain $pattern]
    if {[llength $matches] == 0} {
        error "No file matches pattern: $pattern"
    }
    file copy -force [lindex $matches 0] $destination
}

proc ax7203_write_evidence {path lines} {
    file mkdir [file dirname $path]
    set fh [open $path w]
    foreach line $lines {
        puts $fh $line
    }
    close $fh
}

proc ax7203_build_board_rom {script_dir} {
    set rom_build_py "$script_dir/scripts/build_rom_image.py"
    if {![file exists $rom_build_py]} {
        error "Missing ROM builder script: $rom_build_py"
    }

    set default_rom "$script_dir/../rom/test_fpga_uart_board_diag.s"
    set rom_asm [file normalize [ax7203_env_or_default AX7203_ROM_ASM $default_rom]]
    set rom_march [ax7203_env_or_default AX7203_ROM_MARCH ""]

    if {![file exists $rom_asm]} {
        error "Board ROM source not found: $rom_asm"
    }

    set launchers {}
    if {[info exists ::env(PYTHON_BIN)] && $::env(PYTHON_BIN) ne ""} {
        lappend launchers [list [file normalize $::env(PYTHON_BIN)]]
    }

    foreach candidate [list [list py -3] [list python] [list python3]] {
        set resolved [auto_execok [lindex $candidate 0]]
        if {$resolved eq ""} {
            continue
        }
        if {[file pathtype $resolved] ne "relative" && ![file exists $resolved]} {
            continue
        }
        set launcher [list $resolved]
        foreach arg [lrange $candidate 1 end] {
            lappend launcher $arg
        }
        lappend launchers $launcher
    }

    set script_args [list $rom_build_py --asm $rom_asm]
    if {$rom_march ne ""} {
        lappend script_args --march $rom_march
    }

    set last_err ""
    set saved_pyhome "__ax7203_unset__"
    set saved_pypath "__ax7203_unset__"
    if {[info exists ::env(PYTHONHOME)]} {
        set saved_pyhome $::env(PYTHONHOME)
        unset ::env(PYTHONHOME)
    }
    if {[info exists ::env(PYTHONPATH)]} {
        set saved_pypath $::env(PYTHONPATH)
        unset ::env(PYTHONPATH)
    }

    foreach launcher $launchers {
        set cmd [concat $launcher $script_args]
        puts "INFO: Building board ROM with [join $launcher { }]"
        if {[catch {exec {*}$cmd} build_out]} {
            set last_err $build_out
            puts "WARNING: Board ROM builder failed with [join $launcher { }]"
            puts "WARNING: $build_out"
            continue
        }
        if {$saved_pyhome eq "__ax7203_unset__"} {
            catch {unset ::env(PYTHONHOME)}
        } else {
            set ::env(PYTHONHOME) $saved_pyhome
        }
        if {$saved_pypath eq "__ax7203_unset__"} {
            catch {unset ::env(PYTHONPATH)}
        } else {
            set ::env(PYTHONPATH) $saved_pypath
        }
        puts $build_out
        return
    }

    if {$saved_pyhome eq "__ax7203_unset__"} {
        catch {unset ::env(PYTHONHOME)}
    } else {
        set ::env(PYTHONHOME) $saved_pyhome
    }
    if {$saved_pypath eq "__ax7203_unset__"} {
        catch {unset ::env(PYTHONPATH)}
    } else {
        set ::env(PYTHONPATH) $saved_pypath
    }

    error "Failed to build board ROM image. Last output: $last_err"
}

proc ax7203_clear_run_markers {runs_dir} {
    if {![file exists $runs_dir]} {
        return
    }

    set stale_markers [list \
        "__synthesis_is_running__" \
        "__implementation_is_running__" \
        "__init_design_is_running__" \
        "__write_bitstream_is_running__" \
        ".vivado.begin.rst" \
        ".vivado.end.rst" \
        ".vivado.error.rst" \
        ".Vivado_Synthesis.queue.rst" \
        ".Vivado_Impl.queue.rst" \
        ".Vivado_init_design.queue.rst" \
        ".Vivado_write_bitstream.queue.rst" \
    ]

    foreach run_dir [glob -nocomplain -directory $runs_dir *] {
        if {![file isdirectory $run_dir]} {
            continue
        }
        foreach marker $stale_markers {
            set marker_path [file join $run_dir $marker]
            if {[file exists $marker_path]} {
                file delete -force $marker_path
            }
        }
    }
}

proc ax7203_reset_runs_matching {pattern} {
    foreach run_obj [get_runs -quiet $pattern] {
        catch {reset_run $run_obj}
    }
}

proc ax7203_launch_ip_synth_runs {timeout_seconds jobs} {
    set child_runs {}
    foreach run_obj [get_runs -quiet *_synth_1] {
        set run_name [get_property NAME $run_obj]
        if {$run_name ne "synth_1"} {
            lappend child_runs $run_name
        }
    }

    if {[llength $child_runs] == 0} {
        return
    }

    puts "Launching dependent IP synthesis runs: [join $child_runs { }]"
    launch_runs $child_runs -jobs $jobs
    foreach run_name $child_runs {
        ax7203_wait_run_with_timeout $run_name $timeout_seconds
    }
}

proc ax7203_run_generated_vivado_tcl {run_script timeout_seconds {log_name ""}} {
    if {![file exists $run_script]} {
        error "Generated Vivado Tcl not found: $run_script"
    }

    set vivado_bin [info nameofexecutable]
    if {$vivado_bin eq ""} {
        error "Unable to resolve the current Vivado executable path."
    }
    set vivado_dir [file dirname $vivado_bin]
    set vivado_wrapper [file join [file dirname [file dirname $vivado_dir]] vivado.bat]
    if {[file exists $vivado_wrapper]} {
        set vivado_bin $vivado_wrapper
    }

    set run_dir [file dirname $run_script]
    set script_name [file tail $run_script]
    if {$log_name eq ""} {
        set log_name "[file rootname $script_name].direct.vds"
    }

    set saved_pwd [pwd]
    set start_time [clock seconds]
    set cmd [list [file nativename $vivado_bin] \
        -log $log_name \
        -mode batch \
        -messageDb vivado.pb \
        -notrace \
        -source $script_name]

    puts "INFO: Running generated Vivado Tcl directly: $run_script"
    puts "INFO: Command: [join $cmd { }]"

    cd $run_dir
    set run_output ""
    set run_code 0
    if {[catch {exec {*}$cmd} run_output run_opts]} {
        set run_code 1
    }
    cd $saved_pwd

    puts $run_output

    set elapsed [expr {[clock seconds] - $start_time}]
    if {$elapsed > $timeout_seconds} {
        error "Generated Vivado Tcl exceeded timeout budget (${timeout_seconds}s): $run_script"
    }
    if {$run_code != 0} {
        error "Generated Vivado Tcl failed: $run_script"
    }

    return $elapsed
}
