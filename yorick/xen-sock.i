/*
 * xen-sock.i -
 *
 * Mangement of the socket connection for the XEN infrastructure.
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
local _xen_io_sock;     // symmetric socket connection to peer
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

     Launch or shutdown XEN server.

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
    if (!is_void(_xen_io_sock)) {
        // Only one peer is allowed.
        // FIXME: _xen_reply, sock, "ERROR", 0, "Only one peer is allowed";
        close, sock;
        return;
    }
    _xen_io_sock = listener(_xen_on_recv);
    if (_xen_connect_once) {
        // Shutdown server after first successful peer connection.
        xen_shutdown;
    }
    if (_xen_debug > 0) {
        xen_info, "Connection of peer client has been accepted";
    }
}

func xen_get_server_port(nil)
/* DOCUMENT port = xen_get_server_port();

     Get the prot number of the XEN server; -1 is returned if no server is
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
        xen_info, "Connection to peer server has been accepted";
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

/*---------------------------------------------------------------------------*/
/* UTILITIES */

func xen_sprintf1(fmt, val)
{
    return swrite(format=fmt, val);
}

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

func _xen_post_result(what, id, ans)
{
    _xen_send, swrite(format="%s:%d:%s", what, id, xen_stringify(ans));
}

func _xen_send(mesg)
/* DOCUMENT _xen_send, mesg;

     Send a message to the peer.  Argument `mesg` is the textual message
     contents.  The peer will receive data of the form: "@size:mesg" where
     "size" is the length of the textual message.

   SEE ALSO: _xen_connect.
 */
{
    // Format the message (add the header) and send the resulting bytes (but
    // the final null) to the peer.
    str = swrite(format="@%d:%s", strlen(mesg), mesg);
    socksend, _xen_io_sock, strchar(str)(1:-1);
}

func xen_stringify(arg)
/* DOCUMENT str = xen_stringify(arg);

     Convert argument `arg` into a string token.

   SEE ALSO:
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
                // Replace backslash characters, then replace double quotes.
                str = arg(i);
                for (;;) {
                    sel = strfind("\\", str, n=4);
                    if (sel(2) == -1) break;
                    str = streplace(str, sel, "\\\\");
                    if (sel(0) == -1) break;
                }
                for (;;) {
                    sel = strfind("\"", str, n=4);
                    if (sel(2) == -1) break;
                    str = streplace(str, sel, "\\\"");
                    if (sel(0) == -1) break;
                }
                // Finally surround by double quotes.
                if (ans) {
                    ans += " \"" + str + "\"";
                } else {
                    ans = "\"" + str + "\"";
                }
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
