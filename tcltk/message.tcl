#
# message.tcl -
#
# Management of messages for Xen infrastructure.
#
#------------------------------------------------------------------------------
#
# This file is part of Xen which is licensed under the MIT "Expat" License.
#
# Copyright (C) 2020, Éric Thiébaut, <https://github.com/emmt/Xen>.
#

namespace eval ::xen::message {

    # Configure Tcl channel `io` for the transmission of Xen messages.
    proc configure_channel {io {blocking false}} {
        # Set buffering to "none" as we want to receive messages as soon as
        # possible.
        fconfigure $io -encoding binary -translation binary \
            -eofchar "" -encoding binary \
            -blocking $blocking -buffering none
    }

    # Send textual message `msg` through the channel `io` in encoding
    # `enc`.  If `enc` is "binary" a binary message is assumed.
    proc send {io enc msg} {
        if {$encoding eq "binary"} {
            # No needs for conversion.
            upvar 0 msg dat
        } else {
            # Convert the message (a regular Tcl string) into binary data with
            # the encoding expected by the peer.
            set dat [encoding convertto $enc $msg]
        }

        # Get the size of the binary data in bytes (note that `string length`
        # yields the number of bytes when applied to binary data while it
        # yields the number of characters when applied to a string).
        set siz [string length $dat]

        # Format the header into ASCII encoding.
        set hdr [encoding convertto "ascii" [format "@%d:" $siz]]

        # Write the header and the body of the message to the peer
        # and flush the connection.
        puts -nonewline $io $hdr
        puts -nonewline $io $dat
        flush $io
    }

    # Parse Xen message header in binary data `dat` starting at offset `off`
    # (in bytes).  The result is a list `{off siz}`.  If no complete message
    # header can be found in `dat` starting at `off`, `siz` is -1 and `off` is
    # unchanged.  If a message header can be parsed, `siz` is the (nonnegative)
    # number of bytes in the message body and `off` is the offset (in bytes) of
    # the message body.
    proc parse_header {buf off} {
        # In the message header, the body size is given in bytes and the buffer
        # contents must be parsed as "bytes" not as characters, hence the use
        # of the `binary` command.  The constants 48, 57, 58 and 64 are the
        # respective ASCII codes for "0", "9", ":" and "@".
        set len [string length $buf]
        if {$len > $off} {
            binary scan $buf "@${off}c" c
            if {c != 64} {
                # Byte is not ASCII '@'.
                error "missing begin message marker"
            }
            set siz 0
            set idx $off
            while {[incr idx] < $len} {
                binary scan $buf "@${idx}c" c
                if {48 <= $c && $c <= 57} {
                    # Byte is ASCII digit.
                    set size [expr {10*$size + ($c - 48)}]
                } else if {$c == 58} {
                    # Byte is ASCII ':'.
                    if {$idx < 2} {
                        error "no message size specified"
                    }
                    return [list [expr {$idx + 1}] $siz]
                } else {
                    set fmt "unexpected byte 0x%02x in message header"
                    error [format $fmt $c]
                }
            }
        }
        return [list $off -1]
    }
}
