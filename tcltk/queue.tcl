#
# queue.tcl -
#
# Implement a simple FIFO queue in Tcl.
#
#------------------------------------------------------------------------------
#
# This file is part of Xen which is licensed under the MIT "Expat" License.
#
# Copyright (C) 2020, Éric Thiébaut, <https://github.com/emmt/Xen>.
#

namespace eval ::xen {
    catch {Queue destroy}; # FIXME:
    ::oo::class create Queue {
        variable my_items; # array storing items
        variable my_first; # index of first item
        variable my_last;  # index of last item

        constructor args {
            set my_first 1
            set my_last  0
            foreach item $args {
                incr my_last
                set my_items($my_last) $item
            }
        }

        # Yield whether the queue is empty.
        method isempty {} {
            expr {$my_first > $my_last}
        }

        # Yield the number of items in the queue.
        method number {} {
            expr {$my_first > $my_last ? 0 : $my_last - $my_first + 1}
        }

        # Push an item on the queue.
        method push item {
            incr my_last
            set my_items($my_last) $item
            return
        }

        # Pop first item out of the queue.
        method pop {} {
            if {$my_first > $my_last} {
                error "the queue is empty"
            }
            set item $my_items($my_first)
            unset my_items($my_first)
            incr my_first
            return $item
        }
    }

    # Provide a simple wrapper.
    proc queue args {
        Queue new {*}$args
    }
}
