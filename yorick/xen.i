/*
 * xen.i -
 *
 * Load Xen code.
 *
 *-----------------------------------------------------------------------------
 *
 * This file is part of Xen which is licensed under the MIT
 * "Expat" License.
 *
 * Copyright (C) 2020, Éric Thiébaut, <https://github.com/emmt/Xen>.
 */

/* The following function is a duplicate of the one in "utils.i" which is
   needed to initialize the paths in Xen software. */
func xen_absdirname(file)
/* DOCUMENT xen_absdirname(file);

     Yields the absolute directory name of `file` which can be a file name or a
     file stream.  The returned string is always an absolute directory name
     (i.e., starting by a "/") terminated by a "/".

   SEE ALSO: dirname, filepath, strfind.
*/
{
  if ((i = strfind("/", (path = filepath(file)), back=1n)(2)) <= 0) {
    error, "expecting a valid file name or a file stream";
  }
  return strpart(path, 1:i);
}

local XEN_HOME, XEN_VERSION;
/* DOCUMENT XEN_HOME
         or XEN_VERSION

     Global variables defined by Xen with respectively the name of the source
     directory of Xen and the version of Xen.

   SEE ALSO: xen_absdirname, current_include.
*/
XEN_VERSION = "0.0.1";
XEN_HOME = xen_absdirname(current_include());

/* Load other components. */
include, XEN_HOME+"xen-mesg.i", 1;
