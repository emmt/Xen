/*
 * xen-mesg.i -
 *
 * Implement Xen messaging system.
 *
 *-----------------------------------------------------------------------------
 *
 * This file is part of Xen which is licensed under the MIT
 * "Expat" License.
 *
 * Copyright (C) 2020, Éric Thiébaut, <https://github.com/emmt/Xen>.
 */

if (!is_scalar(XEN_HOME) || !is_string(XEN_HOME)) {
    error, "include \"xen.i\" first";
}

// Options and global variables.
local _xen_listener;     // server socket to accept connections
local _xen_io_sock;      // symmetric socket connection to peer
local _xen_counter;      // counter to generate identifiers
local _xen_connect_once; // shutdown server after 1st client connection?
local _xen_debug;        // debug level
local _xen_last_message; // last message in queue
local _xen_first_message;// first message in queue
local _xen_script_code;  // code of script to evaluate
local _xen_script_func;  // function to call to evaluate script

if (is_void(_xen_counter)) _xen_counter = 0;
if (is_void(_xen_debug)) _xen_debug = 1;
if (is_void(_xen_connect_once)) _xen_connect_once = 0n;

/*---------------------------------------------------------------------------*/
/* SERVER ROUTINES */

local xen_shutdown, _xen_on_connect;
func xen_server(port)
/* DOCUMENT xen_server, port=0;
         or xen_shutdown;

     Launch a Xen server managed by Yorick or shutdown the Xen server run by
     Yorick (if any).

   SEE ALSO: xen_get_server_port().
 */
{
    if (!is_void(_xen_listener)) {
        error, "server is already running";
    }
    if (is_void(port)) port = 0;
    _xen_listener = socket(port, _xen_on_connect);
    if (_xen_debug > 0) {
        xen_info, swrite(format="Server has been started on port %d",
                         _xen_listener.port);
    }
}

func xen_shutdown(nil)
{
    if (!is_void(_xen_listener)) {
        // close listening socket.
        close, _xen_listener;
        _xen_listener = [];
        if (_xen_debug > 0) {
            xen_info, "Server has been shutdown";
        }
    }
}

func _xen_on_connect(listener)
{
    sock = listener(_xen_on_recv);
    if (!is_void(_xen_io_sock)) {
        // Only one peer is allowed.
        _xen_send_to, sock, "ERR", 0, "only one peer is allowed";
        close, sock;
        return;
    }
    _xen_io_sock = sock;
    if (_xen_connect_once) {
        // Shutdown server after first successful peer connection.
        xen_shutdown;
    }
    if (_xen_debug > 0) {
        xen_info, "Connection of peer client has been accepted";
    }
}

func _xen_send_to(_xen_io_sock, cat, num, str)
/* DOCUMENT _xen_send_to, sock, cat, num, str;

     Send a formatted message to another peer than the default one.

     This function is a hack.  The trick is to use the same name for the socket
     argument (i.e., `_xen_io_sock`) as the extern variable assumed by the
     other routines so that these routines can be used to format and send the
     message.

   SEE ALSO: _xen_on_connect.
 */
{
    xen_send_data, xen_format_message(cat, num, str);
}

func xen_get_server_port(nil)
/* DOCUMENT port = xen_get_server_port();

     Get the port number of the Xen server; -1 is returned if no server is
     running.

   SEE ALSO: xen_server.
 */
{
    return (is_void(_xen_listener) ? -1 : _xen_listener.port);
}

/*---------------------------------------------------------------------------*/
/* MANAGEMENT OF CONNECTION WITH PEER */

local xen_disconnect, xen_reconnect;
func xen_connect(host, port)
/* DOCUMENT xen_connect, host, port;
         or xen_reconnect, host, port;
         or xen_disconnect;

     Connect to peer or disconnect from peer.  The server address and port
     number are specified by `host` and `port` respectively.  `host` can be `-`
     if the server runs on the same (local) host.

     The subroutine `xen_reconnect` forces a reconnection by calling
     `xen_disconnect` and then `xen_connect`.

   SEE ALSO: xen_send.
 */
{
    if (!is_void(_xen_io_sock)) {
        error, "peer is already connected";
    }
    _xen_io_sock = socket(host, port, _xen_on_recv);
    if (_xen_debug > 0) {
        xen_info, "Connection to peer has been accepted by server";
    }
}

func xen_reconnect(host, port) /* DOCUMENTED */
{
    xen_disconnect;
    xen_connect, host, port;
}

func xen_disconnect(quiet) /* DOCUMENTED */
{
    if (!is_void(_xen_io_sock)) {
        close, _xen_io_sock;
        _xen_io_sock = [];
        if (!quiet && _xen_debug > 0) {
            xen_info, "Connection to peer has been closed";
        }
    }
}

func _xen_on_recv(sock)
/* DOCUMENT _xen_on_recv, sock;

      Private subroutine implementing the callback called when baytes are
      available from the peer.

   SEE ALSO: xen_connect, xen_server, xen_push_message.
 */
{
    /* A new message has been sent by the peer (or the peer has closed the
       connection).  The difficulty is that Yorick sockets are in blocking
       mode, so we have to read the header of the message (which gives the size
       of the body of the message) byte by byte.  Once the size of the message
       body is known, it can be read in a single call to `sockrecv`.  As a
       consequence, messages are extracted one by one by each call to this
       callback. */
    if (sock != _xen_io_sock) {
        error, "unexpected socket";
    }
    if (catch(-1)) {
        xen_warn, "Closing connection (" + catch_message + ").";
        xen_disconnect, 1n;
        return;
    }

    /* Read message header one byte at a time. */
    ZERO      = 48; // ASCII code for '0'
    NINE      = 57; // ASCII code for '9'
    SEPARATOR = 58; // ASCII code for ':'
    BEGIN     = 64; // ASCII code for '@'
    buf = array(char, 1);
    cnt = 0;
    size = 0;
    for (;;) {
        if (sockrecv(sock, buf) != 1) {
            _xen_connection_closed_by_peer;
            return;
        }
        ++cnt;
        if (cnt == 1) {
            if (buf(1) != BEGIN) {
                error, "missing begin message marker";
            }
        } else {
            byte = long(buf(1));
            if (ZERO <= byte && byte <= NINE) {
                size = 10*size + (byte - ZERO);
            } else if (byte == SEPARATOR) {
                if (cnt < 3) {
                    error, "no message size specified";
                    return;
                }
                break;
            } else {
                error, swrite(format="unexpected byte 0x%02x in message header",
                              byte);
            }
        }
    }

    if (size > 0) {
        /* Read message body. */
        buf = array(char, size);
        if (sockrecv(sock, buf) < size) {
            error, "truncated message body";
        }
        mesg = strchar(buf);
        if (strlen(mesg) != size) {
            error, "null(s) in message body";
        }
    } else {
        mesg = string();
    }
    xen_push_message, mesg;
}

/*---------------------------------------------------------------------------*/
/* PROCESSING OF MESSAGES */

local XenMessage;
local xen_format_message, xen_parse_message;
/* DOCUMENT msg = xen_format_message(cat, num, str);
         or obj = xen_parse_message(msg);

     The first statement, yields a Xen textual message `msg` given the category
     `cat`, serial number `num` and contents `str` of the message.  Argument
     `cat` and `str` are scalar strings, argument `num` is an integer.

     The second statement, parse the textual Xen message `msg` and returns
     a `XenMessage` instance.

   SEE ALSO: xen_send_command, xen_send_data, xen_send_result.
 */
func xen_format_message(cat, num, str) /* DOCUMENTED */
{
    return swrite(format="%s:%d:%s", cat, num, str);
}

struct XenMessage {
    string   cat; // category of message
    long     num; // serial number
    string  data; // contents of message
    pointer next; // next message or NULL
}

func xen_parse_message(msg) /* DOCUMENTED */
{
    sel = strfind(":", msg, n=2);
    if (sel(0) > 0) {
        num = 0;
        if (sread(strpart(msg, sel(2)+1:sel(3)), num) == 1) {
            return XenMessage(cat = strpart(msg, 1:sel(1)),
                              num = num,
                              data = strpart(msg, sel(4)+1:));
        }
    }
    error, "invalid message format";
}

func xen_more_messages(nil)
/* DOCUMENT xen_more_messages();

     Query whether or not there are unprocessed messages in the queue.

   SEE ALSO: xen_push_message, xen_pop_message.
 */
{
    return !is_void(_xen_first_message);
}

func xen_push_message(msg)
/* DOCUMENT xen_push_message(msg);

     Push a new message in the queue of messages to process.  Argument `msg`
     may be the string in the form accepted by `xen_parse_message` or an
     instance of `XenMessage`.  The message processor is rescheduled
     as needed.

     The processing of messages is done when Yorick is idle and one message at
     a time.  Messages are processed in order, that is the message queue is a
     "First In First Out" queue (FIFO).

   SEE ALSO: xen_parse_message, xen_pop_message, xen_more_messages.
 */
{
    T = structof(msg);
    if (T == string) {
        msg = xen_parse_message(msg);
    } else {
        /* Assume message has already been parsed.  Make a copy of it only if
           it has a successor. */
        if (msg.next) {
            msg = msg;
            msg.next = &[];
        }
    }
    if (is_void(_xen_first_message)) {
        /* The message queue was empty. */
        eq_nocopy, _xen_first_message, msg;
        after, 0.0, _xen_process_messages;
    } else {
        /* The message queue was not empty. */
        _xen_last_message.next = &msg;
    }
    eq_nocopy, _xen_last_message, msg;
}

func xen_pop_message(nil)
/* DOCUMENT msg = xen_pop_message();

     Pop first message out of the queue of messages to process and return it.
     The result is an instance of `XenMessage` or nothing ig the queue was
     empty.  The message processor is automatically rescheduled if there are
     other queued messages.

   SEE ALSO: xen_push_message, xen_more_messages.
 */
{
    if (is_void(_xen_first_message)) {
        /* The message queue is empty. */
        return;
    }
    local msg;
    eq_nocopy, msg, _xen_first_message;
    next = msg.next;
    if (next) {
        /* The message queue will not be empty. */
        eq_nocopy, _xen_first_message, *next;
        after, 0.0, _xen_process_messages;
    } else {
        /* The message queue will be empty. */
        _xen_first_message = [];
        _xen_last_message = [];
        after, -, _xen_process_messages;
    }
    msg.next = &[]; // so that it is ok to re-queue message
    return msg;
}

func _xen_process_messages(nil)
/* DOCUMENT _xen_process_messages;

     Private callback called to process the first pending message in the queue.

   SEE ALSO: xen_pop_message, xen_push_message.
 */
{
    /* The processing of the different categories of messages is delegated to
       different functions because error handling depend on the context. */
    msg = xen_pop_message();
    if (msg.cat == "CMD") {
        _xen_process_command, msg.num, msg.data;
    } else if (msg.cat == "EVT") {
        _xen_process_event, msg.num, msg.data;
    } else if (msg.cat == "OK") {
        _xen_process_result, msg.num, msg.data;
    } else if (msg.cat == "ERR") {
        _xen_process_error, msg.num, msg.data;
    } else {
        write, format="ERROR (%s) %s (cat=%s, num=%d, data=%s)\n",
            "_xen_process_messages", "unknown message category",
            msg.cat, msg.num, msg.data;
    }
}

func _xen_process_command(num, cmd)
{
    /* `_xen_process_command` calls `xen_execute_script` to be able to catch
       compilation errors which is not possible when `include` is called.  In
       case of compilation error, the exact error message goes to Yorick's
       `stdin` and will not be received by the peer but, at least, a syntax
       error will be notified. */
    extern _xen_script_code, _xen_script_func;
    if (catch(-1)) {
        xen_send_error, num, catch_message;
        return;
    }
    ans = [];
    val = xen_execute_script(cmd);
    if (is_void(val)) {
        ans = string();
    } else if (is_scalar(val)) {
        T = structof(val);
        if (T == string) {
            eq_nocopy, ans, val;
        } else if (T == long || T == int || T == int) {
            ans = swrite(format="%d", val);
        } else if (T == double) {
            ans = swrite(format="%#.17g", val);
        } else if (T == float) {
            ans = swrite(format="%#.8g", val);
        }
    }
    if (is_void(ans)) {
        ans = xen_stringify(val);
    }
    xen_send_result, num, ans;
}

func _xen_process_event(num, evt)
{
    write, format="EVENT (%d) %s\n", num, evt;
}

func _xen_process_result(num, ans)
{
    if (_xen_debug) {
        write, format="OK (%d) %s\n", num, ans;
    }
}

func _xen_process_error(num, msg)
{
    write, format="ERROR (%d) %s\n", num, msg;
}

/*---------------------------------------------------------------------------*/
/* SENDING OF MESSAGES */

func xen_send_command(cmd) { return _xen_send_serial("CMD", cmd); }
func xen_send_event(evt)   { return _xen_send_serial("EVT", evt); }
/* DOCUMENT num = xen_send_command(cmd);
         or num = xen_send_event(evt);

     Send a command `cmd` to be evaluated by the peer or signal an event `evt`
     to the peer.  The unique serial number `num` of the message if
     automatically generated and returned to the caller.

   SEE ALSO: xen_send_result, xen_stringify.
 */

func xen_send_result(num, val) { _xen_send_format, "OK",  num, val; }
func xen_send_error(num, msg)  { _xen_send_format, "ERR", num, msg; }
/* DOCUMENT xen_send_result, num, val;
         or xen_send_error, num, msg;

     Report the success or the failure of a previous command received from the
     peer.  Argument `num` is the serial number of the command, `val` is the
     result returned by the command if successful while `msg` is the error
     message.

     Arguments `val` and `msg` must be scalar strings.  The function
     `xen_stringify` may be useful for that.

   SEE ALSO: xen_send_command, xen_stringify.
 */

local _xen_send_format;
local _xen_send_serial;
/* DOCUMENT _xen_send_format, cat, num, str;
         or num = _xen_send_serial(cat, str);

     Low-level functions to send a formatted message.  The call to
     `_xen_send_format` is equivalent to:

         xen_send_data, xen_format_message(cat, num, str);

     The call to `_xen_send_serial` is similar except that the serial number
     `num` is automatically generated and returned to the caller.

   SEE ALSO: xen_send_result, xen_send_result, xen_stringify.
 */

func _xen_send_serial(cat, str)
{
    num = ++_xen_counter;
    xen_send_data, xen_format_message(cat, num, str);
    return num;
}

func _xen_send_format(cat, num, str)
{
    xen_send_data, xen_format_message(cat, num, str);
}

func xen_send_data(data)
/* DOCUMENT xen_send_data, data;

     Send message data to the peer.  Argument `data` is the message contents,
     it can be a scalar string, nothing or a numerical array.  If `data` is a
     scalar string, it is first converted into an array of bytes (without the
     final null).  The peer will receive bytes of the form: "@size:data" where
     "size" is the size (in bytes) of the message contents and written in
     decimal notation and ASCII encoding.

   SEE ALSO: _xen_connect, xen_send_command, xen_send_result.
 */
{
    size = -1; // to detect errors
    if (is_array(data)) {
        T = structof(data);
        if (T == string) {
            if (is_scalar(data)) {
                if (strlen(data) > 0) {
                    /* Convert string to bytes without the final null. */
                    data = strchar(data)(1:-1);
                    size = sizeof(data);
                } else {
                    data = [];
                    size = 0;
                }
            }
        } else if (T != pointer) {
            size = sizeof(data);
        }
    } else if (is_void(data)) {
        size = 0;
    }
    if (size < 0) {
        error, "data must be a scalar string, nothing or a numerical array";
    }
    socksend, _xen_io_sock, strchar(swrite(format="@%d:", size))(1:-1);
    if (size > 0) {
        socksend, _xen_io_sock, data;
    }
}

/*---------------------------------------------------------------------------*/
/* UTILITIES */

func xen_execute_script(script)
/* DOCUMENT ans = xen_execute_script(script);

     Compile and execute Yorick code specified by `script` (a scalar string).
     The code is wrapped into an anonymous function and the returned result
     `ans` is given by the first `return` statement in `script` which is
     excecuted or nothing if there is no such statement.

     For instance:

         xen_execute_script("return sqrt(2);")

     yields the value 1.41411 while:

         xen_execute_script("sqrt(2);")

     yields nothing but prints "1.41411" on the standard output because
     the result of the expression is not assigned to a variable.  To avoid
     this:

         xen_execute_script("dummy = sqrt(2);")

     Note that the variable `dummy` above is local to the anonymous function
     and has thus no side effects.

     The code specified by `script` may be arbitrarily complex as far as it
     constitutes valid Yorick code inside a function.  The scoping rules for
     the symbols used in `script` are the same as for any other Yorick
     function.  In the above example, `sqrt` is extern while `dummy` is local.
     Statements like `local` and `extern` may be used in `script` to override
     implicit rules.

   SEE ALSO: include.
 */
{
    extern _xen_script_code, _xen_script_func;

    /* Compile script and call the resulting function. */
    if (is_void(_xen_script_code)) {
        _xen_script_code = ["func _xen_script_func(nil) {", string(), "}"];
    }
    _xen_script_code(2) = script;
    _xen_script_func = 0; /* Anything not a function to detect compilation
                             errors. */
    include, _xen_script_code, 1;
    if (is_func(_xen_script_func)) {
        return _xen_script_func();
    }
    error, "syntax error";
}

func xen_warn(mesg)
{
    write, format="WARNING - %s\n", mesg;
}

func xen_info(mesg)
{
    write, format="INFO - %s\n", mesg;
}

func _xen_eval(num, fn, arg1, arg2, arg3, arg4, arg5, arg6, arg7)
/* DOCUMENT _xen_eval, num, fn, arg1, arg2, ...;

     Evaluate a command sent by the peer and manage to send back the result of
     this call (whether the call is successful or not).  `num` is the
     identifier, `fn` the function to call, `arg1`, `arg2`, etc. the arguments.
     This sub-routine is intented to be called via `funcdef`:

         funcdef("_xen_eval num fn arg1 arg2 ...")

   SEE ALSO: funcdef.
 */
{
    if (catch(-1)) {
        _xen_post_result, "ERROR", num, catch_message;
    } else {
        /*  */ if (! is_void(arg7)) {
            ans = fn(arg1, arg2, arg3, arg4, arg5, arg6, arg7);
        } else if (! is_void(arg6)) {
            ans = fn(arg1, arg2, arg3, arg4, arg5, arg6);
        } else if (! is_void(arg5)) {
            ans = fn(arg1, arg2, arg3, arg4, arg5);
        } else if (! is_void(arg4)) {
            ans = fn(arg1, arg2, arg3, arg4);
        } else if (! is_void(arg3)) {
            ans = fn(arg1, arg2, arg3);
        } else if (! is_void(arg2)) {
            ans = fn(arg1, arg2);
        } else {
            ans = fn(arg1);
        }
        _xen_post_result, "OK", num, ans;
    }
}

func xen_stringify(arg)
/* DOCUMENT str = xen_stringify(arg);

     Convert argument `arg` into a string.

   SEE ALSO: print, print_format, xen_set_print_format.
 */
{
    arr = print(arg);
    return numberof(arr) == 1 ? arr(1) : sum(arr);
}

func xen_set_print_format
/* DOCUMENT xen_set_print_format;

      Set format strings for `print` so as to not loose precision for floating
      point numbers.

   SEE ALSO: print, print_format, xen_stringify.
 */
{
    line_length = 80;
    max_lines = 10000;
    print_format, line_length, max_lines,
        char="0x%02x", short="%d", int="%d", long="%ld",
        float="%#.8gf", double="%#.17g", complex="%#.17g+%#.17gi";
}

xen_set_print_format;
