#
# channel.tcl -
#
# Management of message channels for Xen infrastructure.
#
#------------------------------------------------------------------------------
#
# This file is part of Xen which is licensed under the MIT "Expat" License.
#
# Copyright (C) 2020, Éric Thiébaut, <https://github.com/emmt/Xen>.
#

namespace eval ::xen {

    # A Xen Channel instance is an i/o connection for sending/receiving
    # messages.
    catch {Channel destroy}; # FIXME:
    ::oo::class create Channel

    # Xen Client class.
    catch {Client destroy}; # FIXME:
    ::oo::class create Client

    # Xen Server class.
    catch {Server destroy}; # FIXME:
    ::oo::class create Server

    # Provide convenient wrappers.
    proc channel args {
        Channel new {*}$args
    }
    proc client args {
        Client new {*}$args
    }
    proc server args {
        Server new {*}$args
    }

    # Syntax:
    #
    #     ::xen::channel $chn ?$enc?
    #
    # Yield a new Xen Channel instance using Tcl channel `$chn` for sending and
    # receiving messages.  Optional argument `$enc` is to specify the encoding
    # assumed for textual messages.  By default, `iso8859-1` is assumed.  Call
    # `encoding names` for a list of supported encodings.
    #
    # The result is the name of the Xen Channel instance.
    #
    #     $obj encoding;  # yields current encoding for textual messages
    #     $obj channel;   # yields i/o channel
    #     $obj counter;   # yields number of command/event messages sent to
    #                     # the peer
    #
    # To send a command `$cmd` to be evaluated by the peer or an event `$evt`:
    #     set id [$obj send_command $cmd]
    #     set id [$obj send_event $evt]
    #
    # To report the success or the failure of a previous command received from
    # the peer, call:
    #
    #     $obj send_result $id $val
    #     $obj send_error $id $msg
    #
    # where `$id` is the serial number of the command, `$val` is the result
    # returned by the command if successful while `$msg` is the error message.
    #
}

namespace eval ::xen::channel::priv {
    # Default callback to process received messages.
    proc process {obj msg} {
        puts stderr "\[recv from $obj\] $msg"
    }
}

# Definitions of Xen Channel class.
::oo::define ::xen::Channel {
    #
    # Instance variables are:
    #
    # - `my_cnt`: counter to generate unique serial numbers;
    # - `my_io`:  i/o channel to communicate with the peer;
    # - `my_enc`: encoding assumed for textual messages, can be "binary";
    # - `my_buf`: buffer of unprocessed bytes;
    # - `my_off`: offset to next message header/body in buffer;
    # - `my_siz`: size of next message body in buffer, -1 if unknown yet;
    # - `my_cbk`: callback to process received messages.
    #
    # If `$my_siz` < 0, then `$my_off` is the offset of the next message
    # header.  If `$my_siz` >= 0, then `$my_siz` and `$my_off` are respectively
    # the size (in bytes) and the offset of the next message contents.
    #
    # The callback is called at the toplevel as:
    #
    #    uplevel #0 $my_cbk [list $obj $msg]
    #
    # where `$obj` is the object instance (as returned by `self`) and `$msg`
    # the message contents.
    #
    # Note: The `my_` prefix for instance variables is purely a matter of
    # conventions in Xen.  This makes clear which variables are object
    # variables and also helps converting the code into other languages (e.g.,
    # a variable `my_var` translates as `self.var` in Python).
    #
    variable my_cnt
    variable my_io
    variable my_enc
    variable my_buf
    variable my_off
    variable my_siz
    variable my_cbk

    constructor {chn {enc "iso8859-1"}} {
        if {$enc ne "binary" && $enc ni [encoding names]} {
            error "invalid encoding \"$enc\""
        }
        ::xen::message::configure_channel $chn
        fileevent $chn readable [callback _receive]
        set my_cnt  0
        set my_io   $chn
        set my_enc  $enc
        set my_cbk  ::xen::channel::priv::process
        set my_buf  ""
        set my_off  0
        set my_siz -1
    }

    destructor {
        catch {
            puts stderr "Closing $my_io..."
            fileevent $my_io readable {}
            close $my_io
        }
    }

    # Accessors.

    # Yield encoding.
    method encoding {} {
        set my_enc
    }

    # Yield i/o channel.
    method channel {} {
        set my_io
    }

    method set_processor cbk {
        if {[llength $cbk] == 0} {
            set my_cbk ::xen::channel::priv::process
        } else {
            set my_cbk $cbk
        }
    }

    # Send a command to the peer and return its serial number.
    method send_command cmd {
        set id [incr my_cnt]
        ::xen::message::send $my_io \
            [::xen::message::format_contents "CMD" $id $cmd] $my_enc
        return $id
    }

    # Send an event to the peer and return its serial number.
    method send_event evt {
        set id [incr my_cnt]
        ::xen::message::send $my_io \
            [::xen::message::format_contents "EVT" $id $evt] $my_enc
        return $id
    }

    # Report the success of a previous command received from the peer.
    method send_result {id val} {
        ::xen::message::send $my_io \
            [::xen::message::format_contents "OK" $id $val] $my_enc
    }

    # Report the failure of a previous command received from the peer.
    # By convention, `$id` is 0 if it is an error unrelated to a specific
    # command.
    method send_error {id msg} {
        ::xen::message::send $my_io \
            [::xen::message::format_contents "ERR" $id $msg] $my_enc
    }

    # Private callback for receiving messages.
    method _receive {} {
        try {
            # Note that `string length` yields size in bytes for binary data.
            set dat [read $my_io]
            if {[string length $dat] > 0} {
                append my_buf $dat
                set len [string length $my_buf]
                set consumed 0
                while {true} {
                    # Is there a (complete) pending message?
                    if {$my_siz < 0} {
                        # Header of next message has not yet been parsed.
                        # Attempt to parse it.
                        lassign [::xen::message::parse_header \
                                     $my_buf $my_off] my_off my_siz
                        if {$my_siz < 0} {
                            # No complete header found.
                            break
                        }
                    }
                    if {$len < $my_off + $my_siz} {
                        # Not enough collected data for the body of the
                        # message.
                        break
                    }

                    # Extract message body as a string using the encoding
                    # assumed by the peer.
                    if {$my_siz > 0} {
                        binary scan $my_buf "@${my_off}a${my_siz}" msg
                        if {$my_enc ne "binary"} {
                            set msg [encoding convertfrom $my_enc $msg]
                        }
                    } else {
                        set msg ""
                    }

                    # Update offset, number of consumed bytes and size of
                    #contents for next message.
                    set consumed [incr my_off $my_siz]
                    set my_siz -1

                    # Process the message.
                    # FIXME: use a message queue and an idler
                    # FIXME: parse message contents
                    uplevel #0 $my_cbk [list [self] $msg]
                }
                if {$consumed > 0} {
                    # Truncate buffer.
                    if {$consumed >= $len} {
                        set my_buf ""
                    } else {
                        binary scan $my_buf "@${consumed}a*" my_buf
                    }
                    set my_off [expr {$my_off - $consumed}]
                }
            }
        } on error {result options} {
            puts stderr "Closing message channel on error for [self]"
            my destroy
            return -options $options $result
        }
    }

}

# Definitions of Xen Client class.
::oo::define ::xen::Client {
    superclass ::xen::Channel
    constructor {host port} {
        next [socket $host $port]
    }
    destructor {
        next
    }
}

# Definitions of Xen Server class.
::oo::define ::xen::Server {
    variable my_sock; # listening socket
    variable my_maxclients; # max. number of clients
    variable my_peers; # list of connections to peers (Channel instances)

    destructor {
        foreach peer $my_peers {
            catch {$peer destroy}
        }
        catch {close $my_sock}
    }

    constructor args {
        # Parse arguments (FIXME: detect options specified more than once).
        if {[llength $args]%2 != 0} {
            error "value for \"[lindex $args end]\" is not specified"
        }
        array set opt {
            -addr       "localhost"
            -port        0
            -maxclients -1
        }
        foreach {key val} $args {
            if {![info exists opt($key)]} {
                error "unknown option \"$key\""
            }
            set opt($key) $val
        }
        if {[catch {incr opt(-port) 0}] || $opt(-port) < 0} {
            error "invalid value for option \"-port\""
        }
        if {[catch {incr opt(-maxclients) 0}]} {
            error "invalid value for option \"-maxclients\""
        }
        if {$opt(-addr) eq "localhost"} {
            set opt(-addr) "127.0.0.1"
        }

        # Create the listening socket.
        set xargs [list -server [callback _accept]]
        if {$opt(-addr) ne "*"} {
            lappend xargs -myaddr $opt(-addr)
        }
        lappend xargs $opt(-port)
        puts stderr "calling \"[list socket {*}$xargs]\"..."
        set my_sock [socket {*}$xargs]

        # Set other instance variables.
        set my_maxclients $opt(-maxclients)
        set my_peers {}

        # Print some information.
        foreach {addr host port} [chan configure $my_sock -sockname] {
            puts stderr "Listening at addr=$addr, host=$host, port=$port."
        }
    }

    method _accept {sock addr port} {
        if {$my_maxclients != -1 && [llength $my_peers] >= $my_maxclients} {
            puts stderr "Too many clients."
            close $sock
            return
        }
        puts stderr \
            "Accepting connection from client (addr=$addr, port=$port)"
        set peer [::xen::Channel new $sock]
        lappend my_peers $peer
    }

}
