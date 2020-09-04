#
# xen.tcl -
#
# Provide Xen infrastructure.
#
#------------------------------------------------------------------------------
#
# This file is part of Xen which is licensed under the MIT "Expat" License.
#
# Copyright (C) 2020, Éric Thiébaut, <https://github.com/emmt/Xen>.
#

# Source library scripts.

namespace eval ::xen {
    variable library
    if {![info exists library]} {
        set library [file dirname [info script]]
    }
}

source [file join $::xen::library "subprocess.tcl"]
source [file join $::xen::library "message.tcl"]
#source [file join $::xen::library "channel.tcl"]
#source [file join $::xen::library "console.tcl"]

package provide Xen 1.0
