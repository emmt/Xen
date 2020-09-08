#
# message.tcl -
#
# Low level management of messages for Xen infrastructure.
#
#------------------------------------------------------------------------------
#
# This file is part of Xen which is licensed under the MIT "Expat" License.
#
# Copyright (C) 2020, Éric Thiébaut, <https://github.com/emmt/Xen>.
#

namespace eval ::xen::message {
    #
    # Configure channel for message transmission.
    #
    # The call:
    #
    #     configure_channel $io ?$blocking?
    #
    # configures Tcl channel `$io` for the transmission of Xen messages.
    # Optional argument $blocking` (`false` by default) indicates whether the
    # channel should be blocking or not.
    #
    proc configure_channel {io {blocking false}} {
        # Set buffering to "none" as we want to receive messages as soon as
        # possible.
        fconfigure $io \
            -translation binary \
            -encoding binary \
            -eofchar "" \
            -blocking $blocking \
            -buffering none
    }

    #
    # Send a message through a channel.
    #
    # The call:
    #
    #     ::xen::message::send $io $msg ?$enc?
    #
    # sends message `$msg` through the channel `$io` in encoding `$enc`.  If
    # `$enc` is `binary` (the default) a binary message is assumed; otherwise,
    # a textual message is assumed and `$msg` is converted into binary data
    # with encoding `$enc`.  The channel is flushed after writing the message.
    #
    proc send {io msg {enc "binary"}} {
        if {$enc ne "binary"} {
            # Convert the message (a regular Tcl string) into binary data with
            # the encoding expected by the peer.
            set msg [encoding convertto $enc $msg]
        }

        # Get the size of the binary data in bytes (note that `string length`
        # yields the number of bytes when applied to binary data while it
        # yields the number of characters when applied to a string).
        set siz [string length $msg]

        # Format the header into ASCII encoding.
        set hdr [encoding convertto "ascii" [format "@%d:" $siz]]

        # Write the header and the contents of the message to the peer and
        # flush the connection.
        puts -nonewline $io $hdr
        puts -nonewline $io $msg
        flush $io
    }

    #
    # Parse message header.
    #
    # The call:
    #
    #     ::xen::message::parse_header $buf $off
    #
    # attempts to parse a message header in binary data `buf` starting at
    # offset `off` (in bytes).  The result is a list `{off siz}`.  If no
    # complete message header can be found in `buf` starting at `off`, `siz` is
    # -1 and `off` is unchanged.  If a message header can be parsed, `siz` is
    # the (nonnegative) number of bytes in the message contents and `off` is
    # the offset (in bytes) of the message contents (the header-contents
    # separator is thus at index `$off - 1` in that case).
    #
    proc parse_header {buf off} {
        # In the message header, the contents size is given in bytes and the
        # buffer contents must be parsed as "bytes" not as characters, hence
        # the use of the `binary` command.  The constants 48, 57, 58 and 64 are
        # the respective ASCII codes for "0", "9", ":" and "@".
        set len [string length $buf]
        if {$len > $off} {
            binary scan $buf "@${off}c" c
            if {$c != 64} {
                # Byte is not ASCII '@'.
                error "missing begin message marker"
            }
            set siz 0
            set idx $off
            while {[incr idx] < $len} {
                binary scan $buf "@${idx}c" c
                if {48 <= $c && $c <= 57} {
                    # Byte is ASCII digit.
                    set siz [expr {10*$siz + ($c - 48)}]
                } elseif {$c == 58} {
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

    #
    # Extract message contents.
    #
    # The call:
    #
    #     ::xen::message::extract_contents $buf $off $siz ?$enc?
    #
    # yields the message contents stored in buffer `$buf` at offset `$off` in
    # bytes.  Argument `$siz` is the size in bytes of the binary data
    # corresponding to the message contents.  If `$enc` is not `binary` (the
    # default value), the message contents is converted into a string assuming
    # encoding `$enc`; otherwise the message contents is returned as binary
    # data.
    #
    # Call `encoding names` for a list of supported encodings.
    #
    proc extract_contents {buf off siz {enc "binary"}} {
        if {[binary scan "@${off}a${siz}" msg] != 1} {
            # The binary `scan command` raises an error for invalid offset
            # and/or size and returns zero if not enough bytes are available.
            error "not enough bytes"
        }
        if {$enc eq "binary"} {
            return $msg
        }
        encoding convertfrom $enc $msg
    }

    #
    # Format a textual mesage.
    #
    # The call:
    #
    #     ::xen::message::format_contents $what $id $txt
    #
    # yields a formatted message contents whose type/purpose is given by
    # `$what` (e.g., `OK`, `ERR`, `CMD` or `EVT`), whose serial number is the
    # integer `$id` and whose textual value is `$txt`.
    #
    proc format_contents {what id txt} {
        format "%s:%d:%s" $what $id $txt
    }

    #
    # Scan the contents of a formatted message.
    #
    # The call:
    #
    #     ::xen::message::parse_contents $msg
    #
    # yields a list `{$what $id $txt}` parsed from textual message contents
    # `$msg`.  This reverses the effect of `::xen::message::format_contents`:
    #
    #`$what` is the message type/purpose, `$id` is the serial number of the
    # message (or answer) and `$txt` is the text of the message.
    #
    proc parse_contents msg {
        set i1 [string first ":" $msg]
        if {$i1 >= 0} {
            set i2 [string first ":" $msg [expr {$i1 + 1}]]
            if {$i2 >= 0} {
                set what [string range $msg 0 [expr {$i1 - 1}]]
                set id   [string range $msg [expr {$i1 + 1}] [expr {$i2 - 1}]]
                set txt  [string range $msg [expr {$i2 + 1}] end]
                if {[catch {incr id 0}] == 0} {
                    return [list $what $id $txt]
                }
            }
        }
        error "invalid message format"
    }
}
