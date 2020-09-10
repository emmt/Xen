# A Tcl/Tk implementation of Xen



## Installation

Xen Tcl/Tk requires that Tcl and Tk but also the TclX extension to be properly
installed.

**TBD**

```.tcl
package require Xen
```

or

```.tcl
source xen.tcl
```


## Message channels

Xen Tcl/Tk provides an object oriented interface to the messaging system.
A simple Xen server can be launched by executing:

```.sh
./server.tcl
```

in the shell and then, in a Tcl session:

```.tcl
source xen.tcl
set obj [::xen::client $host $port]
```

where `$host` and `$port` are the hostname or address and port at which the
server is reachable (these values are suggested when starting the server).

The returned object can be used to communicate with the server.

To send a command `$cmd` to be evaluated by the peer or an event `$evt`, do one
of:

```.tcl
set num [$obj send_command $cmd]
set num [$obj send_event $evt]
```

To report the success or the failure of a previous command received from
the peer, call:

```.tcl
$obj send_result $num $val
$obj send_error $num $msg
```

where `$num` is the serial number of the command, `$val` is the result
returned by the command if successful while `$msg` is the error message.

The communication is assumed to be symmetric, *i.e.* the client may also
receive commands or events from the server.  In fact, the considered instance
`$obj` may as well be the one connected to the client on the server side.

The behavior depends on the procedure called to respond to messages.  By
default, received commands are executed and their success or failure is
reported to the peer.  Other received messages are printed to the standard
error output.

To implement a different behavior, provide a processor script by calling:

```.tcl
$obj set_processor $script
```

where, for each received message, `$script` will be called (at the top level)
as:

```.tcl
uplevel #0 $script $obj $cat $num $msg
```

where `$obj` is the connection instance, `$cat` is the message category (`CMD`,
`OK`, `ERR` or `EVT`), `$num` is the serial number of the message and `$msg` the
message contents.

To restore the default behavior:

```.tcl
$obj set_processor {}
```

The following conventions hold:

- If `$cat` is `CMD`, the peer has sent a command (*e.g.* by calling its
  `send_command` method), `$num` is the unique serial number of this command and
  `$msg` is the command to execute.  The peer expects a response sent by the
  `send_result` or the `send_error` methods with the same serial number `$num`
  as the received command.

- If `$cat` is `OK`, the command number `$num` sent to the peer was successful
  and `$msg` is the result returned by evaluating this command.

- If `$cat` is `ERR`, the command number `$num` sent to the peer has failed
  and `$msg` is the corresponding error message.

- If `$cat` is `EVT`, the peer is signalling an event whose serial number and
  assiocated contents are `$num` and `$msg`.  No response is expected by the
  peer (although the event may trigger the sending of a command or of another
  event to the peer, it is up to you).

A possible processor script is:

```.tcl
proc process {obj cat num msg} {
    switch -exact -- $cat {
        CMD {
            set code [catch {uplevel #0 $msg} result]
            if {$code == 0} {
                $obj send_result $num $result
            } elseif {$code == 1} {
                $obj send_error $num $result
            } else {
                $obj send_error $num "code=$code, $result"
            }
        }
        OK {
            puts stderr "Result of command #$num: $msg"
        }
        ERR {
            puts stderr "Error for command #$num: $msg"
        }
        EVT {
            puts stderr "Received event #$num: $msg"
        }
    }
}
```

A better implementation would be to have callbacks associated with the response
to each command and with events (instead of just printing these messages).

Note that, in the current implementation, responses to a command are
asynchronous, they may arrive in any order and at any time later.
Commands are however executed in the order they are received.


## Sub-processes

Xen command `::xen::spawn` can be called to launch a sub-process in
the background.  For instance:

```.tcl
set process [::xen::spawn $command ...]
```

where `$command` is the path to the executable and the ellipsis stands for any
subsequent arguments (Tcl syntax `{*}$args` may be handy to unpack a list of
arguments).  The result of a successful `::xen::spawn` is a `xen::Subprocess`
instance.  The spawned process runs in the background with its standard input
and outputs (`stdin`, `stdout` and `stderr`) connected to the Tcl shell.  The
process identifier (PID) and the channels connected to the spawned process can
be retrieved by *accessor* methods:

```.tcl
$process pid
$process stdin
$process stdout
$process stderr
```

which respectively yield the PID of the spawned process, the writable channel
connected to the standard input of the spawned process, the readable channel
connected to the standard output of the spawned process and the readable
channel connected to the error output of the spawned process.  Initially, the
readable channels connected to the spawned process are configured in
non-blocking mode and all channels connected to the spawned process assumes
the encoding given by `encoding system`.

The `encoding` method can be used to query or set the assumed ancoding:

```.tcl
$process encoding;      # yields the current encoding
$process encoding $enc; # set the encoding to $enc
```

To send some text, say `$str`, to the spawned process, call the `send` method:

```.tcl
$process send $str
```

The string `$str` will be written to the standard input of the spawned process
using the current encoding.  The `send` method also takes care of flushing the
standard input of the spawned process.

The `kill` method may be used to send a signal to the spawned process:

```.tcl
$process kill $signal
```

where `$signal` is a signal name like `SIGINT`.

To patiently wait for the spawned process to terminate, call the `wait` method:

```.tcl
$process wait
```

this may however block forever.  Call the `bury` method to force the spawned
process to terminate:

```.tcl
$process bury
```

These two methods return the same result as TclX `wait` command.  After calling
the methods `wait` or `burry`, the spawned process and its resources are no
longer accessible.
