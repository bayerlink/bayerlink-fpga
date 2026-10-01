# Copyright 2026 Serge Rabyking
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# dvi2rgb as a bayerlink front end: what its vendor IP needs at synthesis.
#
# Sourced through the receiver.tcl a build generates, which wraps it under
# the generic name a synthesis run calls. The front end's cells, settings
# and pins are a board's, described in that board's block library.

# dvi2rgb's EDID ROM reads its .data file RELATIVE at synth time; the
# launch_runs flow would have copied it beside the run. A batch flow
# that synthesises in its own process is the run, so it calls this
# first, from the run's directory.
proc dvi2rgb_synth_prep {ip_repo} {
    foreach f [glob -nocomplain [file join $ip_repo ip dvi2rgb src *.data]] {
        file copy -force $f [pwd]
    }
}
