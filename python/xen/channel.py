#! /usr/bin/env python3
# -*- coding: utf-8 -*-

#
# channel.py -
#
# Implement Xen message channels in Python.
#
#------------------------------------------------------------------------------
#
# This file is part of Xen which is licensed under the MIT "Expat" License.
#
# Copyright (C) 2020, Éric Thiébaut, <https://github.com/emmt/Xen>.
#

import os, socket
from collections import deque

class BadMessage(Exception):
    def __init__(self, reason):
        self.reason = reason

# Default encoding:
ENCODING = "utf-8"

class Channel:
    def __init__(self, io, /, encoding = ENCODING):
        #
        # Private variables:
        #
        # - self._cnt  = counter to generate unique serial numbers;
        # - self._io   = i/o channel to communicate with the peer;
        # - self._enc  = encoding assumed for textual messages, can be "binary";
        # - self._buf  = buffer of unprocessed bytes;
        # - self._off  = offset to next message header/body in buffer;
        # - self._siz  = size of next message body in buffer, -1 if unknown yet;
        # - self._cbk  = callback to process received messages.
        # - self._jobs = queue of jobs to process.
        #
        # If `self._siz` < 0, then `self._off` is the offset of the next
        # message header.  If `self._siz` >= 0, then `self._siz` and
        # `self._off` are respectively the size (in bytes) and the offset of
        # the next message contents.
        #
        self._cnt = 0
        self._enc = encoding
        self._io  = io
        self._buf = b""
        self._off = 0
        self._siz = -1
        self._jobs = deque()
        self.set_processor(None)

    def get_processor(self):
        """Query the callback called to process incoming messages."""
        return self._cbk

    def set_processor(self, cbk = None):
        """Set the callback called to process incoming messages.

        Called as:

            self.set_processor(cbk)

        with `cbk` the function to call process incoming messages or `None` to
        restore the default processor.  For each received message, the
        processor is called as:

            cbk(self, cat, num, msg)

        where `self` is the object instance, `cat` is the message category,
        `num` is the serial number of the message and `msg` the message
        contents.

        """
        self._cbk = Channel._default_processor if cbk is None else cbk

    def _default_processor(self, cat, num, msg):
        print("do:", cat, num, msg)

    def get_encoding(self):
        """Query the encoding assumed for textual messages."""
        return self._enc

    def set_encoding(self, enc = None):
        """set the encoding assumed for textual messages.

        Called as:

            self.set_encoding(enc)

        with `enc` the encoding to use or `None` to restore the default encoding.

        """
        self._enc = ENCODING if enc is None else enc

    def send_command(self, cmd):
        """Send a command to be evaluated by the peer.

        Called as:

            self.send_command(cmd) -> num

        with `cmd` the command to execute; yields the serial number
        of the command.

        """
        return self.send_serial("CMD", cmd)

    def send_event(self, evt):
        """Signal an event to the peer.

        Called as:

            self.send_event(evt) -> num

        with `evt` the event to be signaled; yields the serial number of the
        event.

        """
        return self.send_serial("EVT", evt)

    def send_result(self, num, val):
        """Report to the peer the success of a command.

        Called as:

            self.send_result(num, val)

        with `num` the serial number of the command and `val` the value
        returned by the command.

        """
        self.send_format("OK", num, val)

    def send_error(self, num, msg):
        """Report to the peer the failure of a command.

        Called as:

            self.send_error(num, msg)

        with `num` the serial number of the command and `msg` the error
        message.

        """
        self.send_format("ERR", num, msg)

    def send_serial(self, cat, msg):
        """Format and send a textual message to the peer with a new serial
        number.

        Called as:

            self.send_serial(cat, msg) -> num

        with `cat` the message category and `msg` is the text of the message;
        yields `num` the serial number of the message.

        """
        self._cnt += 1
        self.send_format(cat, self._cnt, msg)
        return self._cnt

    def send_format(self, cat, num, msg):
        """Format and send a textual message to the peer.

        Called as:

            self.send_format(cat, num, msg)

        with `cat` the message category, `num` the serial number of the message
        and `msg` the text of the message.

        """
        if not isinstance(cat, str):
            raise TypeError("category must be a string")
        if not isinstance(num, int):
            raise TypeError("serial number must be an integer")
        if not isinstance(msg, str):
            raise TypeError("message must be a string")
        buf = (cat + ":" + str(num) + ":" + msg).encode(encoding=self._enc)
        self._io.send(("@" + str(len(buf)) + ":").encode(encoding="ascii"))
        self._io.send(buf)
        self._io.flush()

    # Private callback for receiving messages from the peer.
    def _receive(self):
        try:
            # Collect all bytes that can be read from the peer.
            bufsiz = 1024 # max. size of chunks to read
            while True:
                buf = self._io.recv(bufsiz)
                if len(buf) > 0:
                    if len(self._buf) > 0:
                        self._buf += buf
                    else:
                        self._buf = buf
                if len(buf) < bufsiz:
                    break

            # Process all complete pending messages.
            ZERO      = 48 # ASCII code for '0'
            NINE      = 57 # ASCII code for '9'
            SEPARATOR = 58 # ASCII code for ':'
            BEGIN     = 64 # ASCII code for '@'
            consumed = 0 # number of bytes processed
            bufsiz = len(self._buf)
            while True:
                if self._siz < 0:
                    # No parsed header yet, attempt to find the next one.
                    if bufsiz > self._off:
                        # Parse the header of the message (in the form
                        # "@SIZE:") byte-by-byte in order to strictly check for
                        # the syntax.  The check has to done even though the
                        # remaining data are obviously truncated (e.g., no full
                        # messages have less than 3 bytes).
                        if self._buf[self._off] != BEGIN:
                            raise BadMessage("Missing begin message marker")
                        size = 0
                        for i in range(self._off + 1, bufsiz):
                            byte = self._buf[i]
                            if ZERO <= byte <= NINE:
                                size = 10*size + (byte - ZERO)
                            elif byte == SEPARATOR:
                                if i <= self._off + 1:
                                    raise BadMessage("No size specified")
                                self._off = i + 1
                                self._siz = size
                                break
                            else:
                                raise BadMessage("Expecting digits or separator")

                    if self._siz < 0:
                        break

                # Is there enough remaining bytes for the message contents?
                if bufsiz < self._off + self._siz:
                    break

                # Extract message contents and convert it into a string.
                if self._siz > 0:
                    buf = self._buf[self._off : self._off + self._siz]
                    msg = buf.decode(self._enc)
                else:
                    msg = ""

                # Update instance variables for next message before parsing
                # message contents.
                self._off += self._siz
                self._siz = -1
                consumed = self._off

                # Parse message into pieces.
                i1 = msg.find(":", 0)
                i2 = msg.find(":", i1 + 1) if i1 >= 0 else -1
                if i2 < i1 + 2:
                    raise BadMessage("Expecting CAT:NUM:MSG")
                cat = msg[:i1]
                num = int(msg[i1+1:i2], base=10)
                msg = msg[i2+1:]

                # Append message to the queue of pending jobs.
                self.push_job((cat, num, msg))

            # All pending complete messages have been extracted, reduce the
            # buffer as needed.
            if consumed > 0:
                self._buf = self._buf[consumed:]
                self._off -= consumed

        except Exception as ex:
            # Close the connection in case of errors.
            self.disconnect()
            raise ex

    def push_job(self, job):
        self._jobs.append(job)
        # FIXME: start processing in the background

    def pop_job(self):
        if len(self._jobs) < 1:
            return None
        return self._jobs.popleft()
        # FIXME: start processing in the background

    def more_jobs(self):
        return len(self._jobs) >= 1

if __name__ == "__main__":
    class FakeSocket:
        def __init__(self):
            self._buf = b""

        def send(self, buf):
            if not isinstance(buf, bytes):
                raise TypeError("expecting bytes")
            self._buf += buf

        def recv(self, n):
            if n < 0:
                buf = b""
            else:
                buf = self._buf[:n]
                self._buf = self._buf[n:]
            return buf

        def flush(self):
            pass

    chn = Channel(FakeSocket())

    # Send/recceive a single message.
    num = chn.send_command("dosomething")
    print(chn._io._buf)
    chn._receive()
    job = chn.pop_job()
    print(job)
    job = chn.pop_job()
    print(job)

    # Send/recceive several messages.
    chn.send_event("something happens!")
    chn.send_result(num, "success!")
    num = chn.send_command("do something wrong")
    chn.send_error(num, "failure :-(")
    print(chn._io._buf)
    chn._receive()
    while chn.more_jobs():
        job = chn.pop_job()
        print(job)
