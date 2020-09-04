# A scripted infrastructure for interaction between GUI and other processes

Xen implements an infrastructure for interconnecting a Graphical User Interface
(GUI) and other processes.

**WARNING** This is work in progress to implement a *proof of concept*.


## Message format

In Xen, the GUI and other processes use bidirectional connections (called
*channels* in Tcl/Tk) to exchange messages.  Pipes and sockets are examples of
such connections.  Messages are transmitted as binary data and have a specific
format to ensure that nothing is lost during the transmission.

For each message, the transmitted data consists in a *header* followed by the
*body* of the message.  For textual messages, the *body* is the text converted
in a given encoding on which the peers agree.  For binary messages, the *body*
is just the binary data.  The *header* is the human readable string `@${size}:`
where `${size}` is the number of bytes (expressed in decimal notation) of the
*body*.  The *header* is encoded in ASCII whatever the type and encoding of the
*body*.  Hence the first byte of the *header* is 64 (ASCII code for `@`), the
last byte of the *header* is 58 (ASCII code for `:`) and all other bytes of the
*header* are in the range 48-57 (ASCII code for `0` and `9` respectively).  In
pseud-code notation, the transmitted data has the form `@${size}:${body}`.

This format yields transmitted data that constitute valid human readable
strings for textual messages and for a variety of encodings (e.g., ASCII, all
8-bit ISO8859 encodings, UTF-8, etc.).  As such they can be easily dealt with
in scripted programming languages or typed/interpreted by humans (for
debugging).

This format is compatible with blocking and non-blocking connections.  For a
blocking connections, reading the message requires to read the header one byte
at a time and then the complete body once its size is known (because the full
header has been received).  For non-blocking connections, as much data as
available can be stored in a buffer until a complete `@${size}:${body}` message
is available.

The encoding of textual messages is assumed known by the peers.  The
possibility to not impose a specific encoding is to allow for textual
communication with processes which cannot easily change their string encoding
(e.g., Yorick assumes ISO8859-1, Julia assumes UTF-8, etc.).

The following Tcl piece of code shows how to encode a textual message `$msg`
using encoding `$enc` and send it through the channel `$io`:

```.tcl
# Convert the message (a regular Tcl string) into binary data with
# the encoding expected by the peer.
set dat [encoding convertto $enc $msg]

# Get the size of the binary data in bytes.
set siz [string length $dat]

# Format the header into ASCII encoding.
set hdr [encoding convertto "ascii" [format "@%d:" $siz]]

# Write the header and the body of the message to the peer
# and flush the connection.
puts -nonewline $io $hdr
puts -nonewline $io $dat
flush $io
```

Note that, in Tcl, `string length` yields the number of bytes when applied to
binary data while it yields the number of characters when applied to a string.

For such messages to be correctly transmitted, it is important to configure
the connection in *binary* mode.  For instance in Tcl:

```.tcl
fconfigure $io -encoding binary -translation binary \
    -eofchar "" -encoding binary
```

or just

```.tcl
fconfigure $io -encoding binary -translation binary
```

for short (as `-translation binary` also sets `-eofchar ""` and `-encoding
binary`).  In addition you may also set the channel in non-blocking mode:

```.tcl
fconfigure $io -blocking false -buffering none
```
