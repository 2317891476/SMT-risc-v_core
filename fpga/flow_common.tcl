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
