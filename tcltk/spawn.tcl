
#
# spawn.tcl -
#
# Spawn a sub-process for Xen infrastructure.
#

namespace eval ::xen {
    set executable /home/eric/ezy/libexec/yorick/bin/yorick

    variable use_tclx

    if {![info exists use_tclx]} {
        if {[catch {package require Tclx} result]} {
            puts stderr "WARNING - Cannot load Tclx package ($result)"
            set use_tclx 0
        } else {
            set use_tclx 1
        }
    }
}

proc ::xen::spawn args {
    # Flush standard outputs before forking sub-process.
    flush stdout
    flush stderr

    # Preset variables to handle errors.
    set pipe_inp {}
    set pipe_out {}
    set pipe_err {}

    try {
        # Create pipes for stdin, stdout and stderr.
        set pipe_inp [chan pipe]
        set pipe_out [chan pipe]
        set pipe_err [chan pipe]

        # Execute sub-process in the background with its standatd input and
        # outputs redirected to the pipes.
        set pid [exec -ignorestderr -keepnewline -- {*}$args \
                     <@ [lindex $pipe_inp 0] \
                     >@ [lindex $pipe_out 1] \
                     2>@ [lindex $pipe_out 1] &]

        # Close unused end of the pipes and set outputs to be in non-blocking
        # mode.
        close [lindex $pipe_inp 0]
        close [lindex $pipe_out 1]
	close [lindex $pipe_err 1]
        set inp [lindex $pipe_inp 1]
	set out [lindex $pipe_out 0]
        set err [lindex $pipe_err 0]
        fconfigure $inp -blocking true
        fconfigure $out -blocking false
        fconfigure $err -blocking false
    } on error {result options} {
        # Close all channels on error.
        foreach chn [concat $pipe_inp $pipe_out $pipe_err] {
            catch {close $chn}
        }
        return -options $options $result
    }

    return [list $pid $inp $out $err]
}

# This command is the same as ::xen::spawn but it is implemented with
# TclX.
proc ::xen::spawn_with_tclx args {
    variable use_tclx
    if {!$use_tclx} {
        error "TclX is required by this function."
    }

    # Flush outputs before forking.
    flush stdout
    flush stderr

    # Preset variables to handle errors.
    set pipe_inp {}
    set pipe_out {}
    set pipe_err {}

    try {
        # Create pipes for stdin, stdout and stderr.
        set pipe_inp [pipe]
        set pipe_out [pipe]
        set pipe_err [pipe]
    } on error {result options} {
        # Close all channels on error.
        foreach chn [concat $pipe_inp $pipe_out $pipe_err] {
            catch {close $chn}
        }
        return -options $options $result
    }

    # Fork current process.
    set pid [fork]
    if {$pid == 0} {
        # We are the children.  Close all open channels other than stdin,
	# stdout and stderr.  Connect one end of each pipe channels to child's
	# standard channels and close the other end of the pipe.  Finally,
	# execute child program.
        #
        # FIXME: Put child in its own process group (setpgid).
        # FIXME: Turn off specific signal handling.
	if [catch {
            foreach chn [chan names] {
                if {$chn ne "stdin" && $chn ne "stdout" && $chn ne "stderr"} {
                    chan close $chn
                }
            }
	    dup [lindex $pipe_inp 0] stdin
	    dup [lindex $pipe_out 1] stdout
	    dup [lindex $pipe_err 1] stderr
            close [lindex $pipe_inp 1]
            close [lindex $pipe_out 0]
            close [lindex $pipe_err 0]
	    execl {*}$args
	}] {
	    exit 1
	}
    } else {
        # We are the parent.  Close unused pipe channels.  Set channels
        # connected to child's outputs to be non-blocking.  Errors are
        # unexpected here.
        try {
            close [lindex $pipe_inp 0]
            close [lindex $pipe_out 1]
            close [lindex $pipe_err 1]
            set inp [lindex $pipe_inp 1]
            set out [lindex $pipe_out 0]
            set err [lindex $pipe_err 0]
            fconfigure $inp -blocking true
            fconfigure $out -blocking false
            fconfigure $err -blocking false
        } on error {result options} {
            # Close all channels on error.
            foreach chn [concat $pipe_inp $pipe_out $pipe_err] {
                catch {close $chn}
            }
            return -options $options $result
        }
        return [list $pid $inp $out $err]
    }
}

namespace eval ::xen {
    # Use spawned process ID as the identifier, perhaps with a prefix.
    variable db

    proc wait_spawned pid {
        wait -nohang $pid
    }

    proc stdin self {
        set ::xen::db($self,inp)
    }

    proc stdout self {
        set ::xen::db($self,out)
    }

    proc stderr self {
        set ::xen::db($self,err)
    }

    proc pid self {
        set ::xen::db($self,pid)
    }

    # ^C should be mapped to `kill SIGINT $id`
    proc kill {signal args} {
        variable use_tclx
        if {$use_tclx} {
            foreach pid $args {
                ::kill $signal $pid
            }
        } else {
            exec kill $signal $args
        }
    }
}


package require Tk
proc gfxwin {win args} {
    frame $win -bd 1 -relief sunken -bg plum; # -class ...
    return $win
}
