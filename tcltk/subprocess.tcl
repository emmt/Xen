#
# subprocess.tcl -
#
# Management of sub-processes for Xen infrastructure.
#
#------------------------------------------------------------------------------
#
# This file is part of Xen which is licensed under the MIT "Expat" License.
#
# Copyright (C) 2020, Éric Thiébaut, <https://github.com/emmt/Xen>.
#

package require Tclx

# Create namesspaces.
namespace eval ::xen::subprocess {
    # Private namespace.
    namespace eval priv {
        variable counter
        if {![info exists counter]} {
            set counter 0
        }
    }

    # Namespace for low-level implementation.
    namespace eval impl {
    }
}

#------------------------------------------------------------------------------
# HIGH-LEVEL INTERFACE

namespace eval ::xen::subprocess {

    proc spawn args {
        # Call low-level implementation and extract members.
        set sub [::xen::subprocess::impl::spawn {*}$args]
        set pid [lindex $sub 0]
	set inp [lindex $sub 1]
	set out [lindex $sub 2]
	set err [lindex $sub 3]

        try {
            # Set channels connected to child's outputs to be non-blocking.
            fconfigure $inp -blocking true
            fconfigure $out -blocking false
            fconfigure $err -blocking false

            # Register process data.
            set numb [incr ::xen::subprocess::priv::counter]
            set process xen_proc$numb
            set varname ::xen::subprocess::priv::$process
            if {[info exists $varname]} {
                error "variable \"$varname\" already exists"
            }
            upvar $varname rec
            set rec(pid) $pid
            set rec(inp) $inp
            set rec(out) $out
            set rec(err) $err
        } on error  {result options} {
            catch {::xen::subprocess::impl::burry $pid $inp $out $err}
            return -options $options $result
        }
        return $process
    }

    proc exists process {
        info exists ::xen::subprocess::priv::${process}
    }

    proc burry process {
        set ans [::xen::subprocess::impl::burry \
                     [::xen::subprocess::pid    $process] \
                     [::xen::subprocess::stdin  $process] \
                     [::xen::subprocess::stdout $process] \
                     [::xen::subprocess::stderr $process]]
        unset -nocomplain -- ::xen::subprocess::priv::${process}
        return $ans
    }

    proc wait process {
        set ans [::xen::subprocess::impl::wait \
                     [::xen::subprocess::pid    $process] \
                     [::xen::subprocess::stdin  $process] \
                     [::xen::subprocess::stdout $process] \
                     [::xen::subprocess::stderr $process]]
        unset -nocomplain -- ::xen::subprocess::priv::${process}
        return $ans
    }

    proc kill {signal process} {
        ::kill $signal [::xen::subprocess::pid $process]
    }

    # Accessors.

    proc pid process {
        set ::xen::subprocess::priv::${process}(pid)
    }

    proc stdin process {
        set ::xen::subprocess::priv::${process}(inp)
    }

    proc stdout process {
        set ::xen::subprocess::priv::${process}(out)
    }

    proc stderr process {
        set ::xen::subprocess::priv::${process}(err)
    }

}

#------------------------------------------------------------------------------
# LOW-LEVEL IMPLEMENTATION

proc ::xen::subprocess::impl::spawn args {
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

proc ::xen::subprocess::impl::wait {pid inp out err} {
    set ans [::wait $pid]
    catch {close $inp}
    catch {close $out}
    catch {close $err}
}

proc ::xen::subprocess::impl::burry {pid inp out err} {
    if {[::infox have_waitpid]} {
        # Maybe the process is already dead.
        set ans [::wait -nohang $pid]
    } else {
        set ans {}
    }
    if {[llength $ans] == 0} {
        # Process cannot be assumed dead.  Send SIGKILL and wait until
        # effective termination.
        ::kill SIGKILL $pid
        set ans [::wait $pid]
    }
    catch {close $inp}
    catch {close $out}
    catch {close $err}
}
