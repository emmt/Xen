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

# Private routines and data.
namespace eval ::xen::channel::priv {
    variable counter;  # counter for instance records
    if {![info exists counter]} {
        set counter 0
    }

    # Default options.
    variable defaults
    proc set_default {key val} {
        variable defaults
        if {![info exists defaults($key)]} {
            set defaults($key) $val
        }
    }

    # Default encoding assumed by the peer.
    set_default encoding "iso8859-1"

    # Default callback to process received messages.
    set_default callback ::xen::channel::priv::on_process
    proc on_process msg {
        puts stderr "\[recv\] $msg"
    }

    # Callback for receiving messages.
    proc on_receive chn {
        upvar 0 ::xen::channel::priv::$chn rec
        try {
            # Note that `string length` yields size in bytes for binary data.
            set dat [read $io]
            if {[string length $dat] > 0} {
                set buf [append $rec(buf) $dat]
                set len [string length $buf]
                set off $rec(off)
                set siz $rec(siz)
                set consumed 0
                while {true} {
                    # Is there a (complete) pending message?
                    if {$rec(siz) < 0} {
                        # Header of next message has not yet been parsed.
                        # Attempt to parse it.
                        lassign [::xen::message::parse_header \
                                     $rec(buf) $rec(off)] rec(off) rec(siz)
                        if {$rec(siz) < 0} {
                            # No complete header found.
                            break
                        }
                    }
                    if {$len < $rec(off) + $rec(siz)} {
                        # Not enough collected data for the body of the
                        # message.
                        break
                    }

                    # Extract message body as a string using the encoding
                    # assumed by the peer.
                    if {$rec(siz) > 0} {
                        binary scan $rec(buf) "@$rec(off)a$rec(siz)" body
                        if {$rec(enc) ne "binary"} {
                            set msg [encoding convertfrom $rec(enc) $body]
                        }
                    } else {
                        set msg ""
                    }

                    # Update offset, number of consumed bytes and message body
                    # size for next message.
                    set consumed [incr rec(off) $rec(siz)]
                    set rec(siz) -1

                    # Process the message.
                    $rec(cbk) $msg
                }
                if {$consumed > 0} {
                    # Truncate buffer.
                    if {$consumed >= $len} {
                        set rec(buf) ""
                    } else {
                        set rec(buf) [string range $rec(off) end $rec(buf)]
                    }
                    set rec(off) [expr {$rec(off) - $consumed}]
                }
            } on error {result options} {
                puts stderr "closing message channel on error"
                ::xen::channel::close $chn
                return -options $options $result
            }
        }
    }
}

# Xen message channel data is stored into array `::xen::channel::priv::$chn`
# with `$chn` the name of the instance (in the form `xen_io$numb` where `$numb`
# is a unique number.  Assuming `rec` is the instance record, the fields are:
#
# - `rec(buf)`: buffer of unprocessed bytes;
# - `rec(off)`: offset to next message header/body in buffer;
# - `rec(siz)`: size of next message body in buffer, -1 if unknown yet;
# - `rec(io)`:  i/o channel for communcating with the peer;
# - `rec(enc)`: encoding assumed by the peer, can be "binary";
# - `rec(cbk)`: callback to process received messages.
#
# If `rec(siz)` < 0, then `rec(off)` is the offset of the next message
# header.  If `rec(siz)` >= 0, then `rec(siz)` and `rec(off)` are
# respectively the size (in bytes) and the offset of the next message body.

namespace eval ::xen::channel {

    # ::xen::channel::create io [-encoding enc] [-callback cbk]
    #
    # Register a new message channel using Tcl channel `io` for
    # sending/receiving the messages.  Options are the encoding of textual
    # messages and the callback for processing received messages.  The callback
    # is called as `cbk msg` with `msg` the received message.
    proc create {io args} {
        # Parse options.
        if {[llength $args]%2 != 0} {
            error "expecting option-value pairs"
        }
        array set opt [array get ::xen::channel::priv::defaults]
        foreach {key val} $args {
            switch -exact -- $key {
                -encoding {
                    set opt(encoding) $val
                }
                -callback {
                    set opt(callback) $val
                }
                default {
                    error "unknown option \"$key\""
                }
            }
        }

        # Configure channel.
        ::xen::message::configure_channel $io

        # New array to store instance data.
        set numb [incr ::xen::channel::priv::counter]
        set name xen_io$numb
        upvar 0 ::xen::channel::priv::$name rec
        if {[info exists rec]} {
            error "array \"::xen::channel::priv::$name\" already exists"
        }
        set rec(buf)  ""; # buffer of unprocessed bytes
        set rec(off)   0; # offset to next message header/body in buffer
        set rec(siz)  -1; # size of next message body in buffer
        set rec(io)  $io; # i/o connection
        set rec(enc) $opt(encoding); # encoding assumed by the peer
        set rec(cbk) $opt(callback); # callback to process received messages
    }

    # Close Xen message channel `chn`.  Associated resources are released
    # and the communication channel is closed.
    proc close chn {
        ::close [::xen::channel::forget $chn]
    }

    # Forget (unregister) the message connection named `$name` and return
    # its communication channel.  Call `::xen::channel::close` to also
    # close the communication channel.
    proc forget chn {
        upvar 0 ::xen::channel::priv::$chn rec
        set io $rec(io)
        unset -nocomplain -- rec
        return $io
    }

    proc send {chn msg} {
        upvar 0 ::xen::channel::priv::$chn rec
        ::xen::message::send $rec(io) $rec(enc) $msg
    }

}
