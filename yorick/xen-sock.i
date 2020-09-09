/*
 * xen-sock.i -
 *
 * Mangement of the socket connection for the Xen infrastructure.
 *
 * The public part of the API which may be called by the peer is kept as simple
 * as possible to be compatible with the limitations of the `funcdef` function.
 *
 *-----------------------------------------------------------------------------
 *
 * This file is part of Xen which is licensed under the MIT
 * "Expat" License.
 *
 * Copyright (C) 2020, Éric Thiébaut, <https://github.com/emmt/Xen>.
 */

// Options and global variables.
local _xen_listener;     // server socket to accept connections
local _xen_io_sock;      // symmetric socket connection to peer
local _xen_counter;      // counter to generate identifiers
local _xen_connect_once; // shutdown server after 1st client connection?
local _xen_debug;        // debug level

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

func _xen_send_to(_xen_io_sock, typ, id, str)
/* DOCUMENT _xen_send_to, sock, typ, id, str;

     Send a formatted message to another peer than the default one.

     This function is a hack.  The trick is to use the same name for the socket
     argument (i.e., `_xen_io_sock`) as the extern variable assumed by the
     other routines so that these routines can be used to format and send the
     message.

   SEE ALSO: _xen_on_connect.
 */
{
    xen_send_data, xen_format_message(typ, id, str);
}

func xen_get_server_port(nil)
/* DOCUMENT port = xen_get_server_port();

     Get the prot number of the Xen server; -1 is returned if no server is
     running.

   SEE ALSO: xen_server.
 */
{
    return (is_void(_xen_listener) ? -1 : _xen_listener.port);
}

/*---------------------------------------------------------------------------*/
/* MANAGEMENT OF CONNECTION WITH PEER */

local xen_disconnect, xen_reconnect, _xen_on_recv;
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

func xen_reconnect(host, port)
{
    xen_disconnect;
    xen_connect, host, port;
}

func xen_disconnect(quiet)
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

    after, 0.0, _xen_process_message, mesg;
}

func _xen_process_message(mesg)
{
    write, format="[recv] %s\n", mesg;
}

local xen_format_message, xen_parse_message;
/* DOCUMENT msg = xen_format_message(typ, id, str);
         or local typ, id, str; xen_parse_message, typ, id, str, msg;

     The first statement, yields a Xen textual message `msg` given the type
     `typ`, serial number `id` and contents `str` of the message.  Argument
     `typ` and `str` are scalar strings, argument `id` is an integer.

     The remaing statements, parse the textual Xen message `msg` into its
     components.

   SEE ALSO: xen_send_command, xen_send_data, xen_send_result.
 */
func xen_format_message(typ, id, str)
{
    return swrite(format="%s:%d:%s", typ, id, str);
}

func xen_parse_message(&typ, &id, &str, msg)
{
    sel = strfind(":", msg, n=2);
    if (sel(0) > 0) {
        id = 0;
        if (sread(strpart(msg, sel(2)+1:sel(3)), id) == 1) {
            typ = strpart(msg, 1:sel(1));
            str = strpart(msg, sel(4)+1:);
            return;
        }
    }
    error, "invalid message format";
}

func xen_send_command(cmd) { return _xen_send_serial("CMD", cmd); }
func xen_send_event(evt)   { return _xen_send_serial("EVT", evt); }
/* DOCUMENT id = xen_send_command(cmd);
         or id = xen_send_event(evt);

     Send a command `cmd` to be evaluated by the peer or signal an event `evt`
     to the peer.  The unique serial number `id` of the message if
     automatically generated and returned to the caller.

   SEE ALSO: xen_send_result, xen_stringify.
 */

func xen_send_result(id, val) { _xen_send_format, "OK",  id, val; }
func xen_send_error(id, msg)  { _xen_send_format, "ERR", id, msg; }
/* DOCUMENT xen_send_result, id, val;
         or xen_send_error, id, msg;

     Report the success or the failure of a previous command received from the
     peer.  Argument `id` is the serial number of the command, `val` is the
     result returned by the command if successful while `msg` is the error
     message.

     Arguments `val` and `msg` must be scalar strings.  The function
     `xen_stringify` may be useful for that.

   SEE ALSO: xen_send_command, xen_stringify.
 */

local _xen_send_format;
local _xen_send_serial;
/* DOCUMENT _xen_send_format, typ, id, str;
         or id = _xen_send_serial(typ, str);

     Low-level functions to send a formatted message.  The call to
     `_xen_send_format` is equivallent to:

         xen_send_data, xen_format_message(typ, id, str);

     The call to `_xen_send_serial` is similar except that the serial number
     `id` is automatically generated and returned to the caller.

   SEE ALSO: xen_send_result, xen_send_result, xen_stringify.
 */

func _xen_send_serial(typ, str)
{
    id = ++_xen_counter;
    xen_send_data, xen_format_message(typ, id, str);
    return id;
}

func _xen_send_format(typ, id, str)
{
    xen_send_data, xen_format_message(typ, id, str);
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

func xen_warn(mesg)
{
    write, format="WARNING - %s\n", mesg;
}

func xen_info(mesg)
{
    write, format="INFO - %s\n", mesg;
}

//_xen_nuller = where(0);

//func xen_extract(data, rng)
//{
//    if (is_void(rng)) {
//        return;
//    }
//    return data(rng(1):rng(2));
//}

func _xen_eval(id, fn, arg1, arg2, arg3, arg4, arg5, arg6, arg7)
/* DOCUMENT _xen_eval, id, fn, arg1, arg2, ...;

     Evaluate a command sent by the peer and manage to send back the result of
     this call (whether the call is successful or not).  `id` is the
     identifier, `fn` the function to call, `arg1`, `arg2`, etc. the arguments.
     This sub-routine is intented to be called via `funcdef`:

         funcdef("_xen_eval id fn arg1 arg2 ...")

   SEE ALSO: funcdef.
 */
{
    if (catch(-1)) {
        _xen_post_result, "ERROR", id, catch_message;
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
        _xen_post_result, "OK", id, ans;
    }
}

func xen_stringify(arg)
/* DOCUMENT str = xen_stringify(arg);

     Convert argument `arg` into a string token or into a list of tokens
     separated by spaces if `arg` is an array of multiple elements.

   SEE ALSO: xen_string_replace_all.
 */
{
    ans = string();
    if (is_void(arg)) {
        return ans;
    }
    if (is_array(arg)) {
        i = 0;
        n = numberof(arg);
        T = structof(arg);
        if (T == string) {
            while (++i <= n) {
                // Replace backslash characters, then replace double quotes and
                // finally surround by double quotes.
                str = xen_string_replace_all(arg(i), "\\", "\\\\");
                str = xen_string_replace_all(str, "\"", "\\\"");
                ans = (ans ? ans + " \"" + str + "\"" : "\"" + str + "\"");
            }
            return ans;
        }
        if (T == long || T == int || T == char || T == short) {
            while (++i <= n) {
                ans = (ans ? swrite(format="%s %d", ans, arg(i)) :
                       swrite(format="%d", arg(i)));
            }
            return ans;
        }
        if (T == double || T == float) {
            while (++i <= n) {
                ans = (ans ? swrite(format="%s %#g", ans, arg(i)) :
                       swrite(format="%#g", arg(i)));
            }
            return ans;
        }
    }
    error, "unexpected argument type";
}

func xen_string_replace_all(str, pat, sub)
/* DOCUMENT xen_string_replace_all(str, pat, sub);

     Replace all occurences of `pat` in string `str` by `sub`.  All arguments
     must be scalar strings (this is not checked for efficiency reasons).

   SEE ALSO: strfind, streplace.
 */
{
    off = 0;
    inc = strlen(sub) - strlen(pat);
    for (;;) {
        // FIXME: make this faster by doing multiple searches
        sel = strfind(pat, str, off);
        end = sel(2);
        if (end < off) break;
        str = streplace(str, sel, sub);
        off = end + inc;
    }
    return str;
}
