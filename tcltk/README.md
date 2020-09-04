# A Tcl/Tk implementation of Xen



## Installation

Xen Tcl/Tk requires that Tcl and Tk but also the TclX extension to be properly
installed.

**TBD**

```.tcl
package require Xen
```


## Sub-processes

Xen command `::xen::subprocess::spawn` can be called to launch a sub-process in
the background.  For instance:

```.tcl
set process [::xen::subprocess::spawn $command ...]
```

where `$command` is the path to the executable and the ellipsis stands for any
subsequent arguments (Tcl syntax `{*}$args` may be handy to unpack a list of
arguments).  The result of a successful `::xen::subprocess::spawn` is the name
of the spawned process.  The spawned process runs in the background with its
standard input and its outputs connected by pipes to the Tcl shell.  The
process identifier (PID) and the channels connected to the spawned process can
be retrieved by:

```.tcl
::xen::subprocess::pid    $process
::xen::subprocess::stdin  $process
::xen::subprocess::stdout $process
::xen::subprocess::stderr $process
```

which respectively yield the PID of the spawned process, the writable channel
connected to the standard input of the spawned process, the readable channel
connected to the standard output of the spawned process and the readable
channel connected to the error output of the spawned process.  The readable
channels connected to the spawned process are configured in non-blocking mode.

To send a signal to a spawned process, call:

```.tcl
::xen::subprocess::kill $signal $process
```

where `$signal` is a signal name like `SIGINT`.

To wait for a spawned process to terminate, call:

```.tcl
::xen::subprocess::wait $process
```

and call:

```.tcl
::xen::subprocess::burry $process
```

to force the spawned process to terminate.  These two commands return the same
result as TclX `wait` command.  After calling `::xen::subprocess::wait` or
`::xen::subprocess::burry`, the spawned process and its resources are no longer
accessible.
