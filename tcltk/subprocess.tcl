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
package require TclOO

namespace eval ::xen {
    variable counter
    if {![info exists counter]} {
        set counter 0
    }
    proc OnRead {id chn} {
        set buf [read $chn]
        puts -nonewline stderr "$id: $buf"
    }

    proc spawn args {
        Subprocess new {*}$args
    }
    catch {Subprocess destroy}; # FIXME:
    oo::class create Subprocess {
        variable my_pid;    # process identifier, -1 if not alive
        variable my_stdin;  # writable channel connected to process stdin
        variable my_stdout; # readable channel connected to process stdout
        variable my_stderr; # readable channel connected to process stderr
        variable my_files;  # list of channels opened by this instance
        variable my_epitaph;# information when process died

        constructor args {
            set my_files {}
            set my_pid -1
            set my_encoding [encoding system]
            try {
                # Open pipe to be connected to sub-process stdout.
                set io [chan pipe]
                lappend my_files {*}$io
                set my_stdout [lindex $io 0]
                fconfigure $my_stdout -blocking 0
                lappend args ">@" [lindex $io 1]

                # Open pipe to be connected to sub-process stderr.
                set io [chan pipe]
                lappend my_files {*}$io
                set my_stderr [lindex $io 0]
                fconfigure $my_stderr -blocking 0
                lappend args "2>@" [lindex $io 1]

                # Launch sub-process and retrieve its PID.
                set my_stdin [open |$args WRONLY]
                lappend my_files $my_stdin
                set my_pid [pid $my_stdin]

                # Configure channels to the same encoding.
                foreach chn [list $my_stdin $my_stdout $my_stderr] {
                    fconfigure $chn -encoding $my_encoding
                }
            } on error {result options} {
                foreach chn $my_files {
                    catch {close $chn}
                }
                if {$my_pid > 0} {
                    ::kill SIGKILL $my_pid
                    ::wait $my_pid
                }
                return -options $options $result
            }
            set my_epitaph {}
        }

        destructor {
            catch {kill SIGKILL $my_pid}
            foreach file $my_files {
                catch {close $file}
            }
        }

        method pid {} {
            set my_pid
        }
        method stdin {} {
            set my_stdin
        }
        method stdout {} {
            set my_stdout
        }
        method stderr {} {
            set my_stderr
        }

        method kill sig {
            kill $sig $my_pid
        }

        method encoding {{enc {}}} {
            if {$enc ne ""} {
                if {$enc in [encoding names]} {
                    foreach chn [list $my_stdin $my_stdout $my_stderr] {
                        fconfigure $chn -encoding $enc
                    }
                    set my_encoding $enc
                }
            }
            set my_encoding
        }

        # Private method to close all files.
        method CloseAll {} {
            set my_stdin ""
            set my_stdout ""
            set my_stderr ""
            foreach chn $my_files {
                catch {close $chn}
            }
            set my_files {}
        }

        method wait {} {
            if {$my_pid > 0} {
                # Patiently wait for the process to end.
                set my_epitaph [::wait $my_pid]
                set my_pid -1

                # Close all associated files.
                my CloseAll
            }
            return $my_epitaph
        }

        method terminate {} {
            if {$my_pid > 0} {
                # Make sure the process is dead and not zombie.
                if {[::infox have_waitpid]} {
                    # Maybe the process is already dead.
                    set my_epitaph [::wait -nohang $my_pid]
                    if {[llength $my_epitaph] > 0} {
                        set my_pid -1
                    }
                }
                if {$my_pid > 0} {
                    # Process cannot be assumed dead.  Send SIGKILL and wait
                    # until effective termination.
                    ::kill SIGKILL $my_pid
                    set my_epitaph [::wait $my_pid]
                    set my_pid -1
                }

                # Close all associated files.
                my CloseAll
            }
            return $my_epitaph
        }

        method isalive {} {
            expr {$my_pid > 0}
        }

        method send cmd {
            puts -nonewline $my_stdin $cmd
            flush $my_stdin
        }

        method suspend {} {
            fileevent $my_stdout readable {}
            fileevent $my_stderr readable {}
        }

        method resume {{script ::xen::OnRead}} {
            fileevent $my_stdout readable [concat $script OUT $my_stdout]
            fileevent $my_stderr readable [concat $script ERR $my_stderr]
        }
    }
}
