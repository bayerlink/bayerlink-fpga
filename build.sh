#!/bin/sh -e
# Copyright 2026 Serge Rabyking
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# The whole build, in the order it has to happen.
#
# Three of the four sources are GENERATED and none is committed: the
# receiver, the ISP and the display raster come from their models. That
# is the point -- there is no hand-edited Verilog to drift -- but it
# means a build that skips a generator fails on a missing file, which is
# the correct failure and the reason this script exists.
#
#   ./build.sh                       1080p60 out, 1920x1080 ISP
#
# ISP_MHZ is the clock the pipeline is CUT for, and it must be the
# link's own pixel clock (148.5 for 1080p): the ISP rides the
# receiver's domain, so a lower number here would silently ask the
# generator for a pipeline too slow for the pixels arriving.
#   MODE=720p60 W=1280 H=720 ./build.sh
#
# Needs: vivado on PATH, and `pip install np2hw bayerlink revela`.
# Also needs vivado-library/ and board-files/ beside this file; see the
# README for the two clone commands.
BOARD=${BOARD:-pynq-z2}
MODE=${MODE:-1080p60}
W=${W:-1920}
H=${H:-1080}
BITS=${BITS:-10}
ISP_MHZ=${ISP_MHZ:-148.5}
RX_FIFO=${RX_FIFO:-256}

here=$(cd "$(dirname "$0")" && pwd)
cd "$here"

echo "== receiver (np2hw bayerlink_in)"
# --fifo-depth is PINNED, not left to the generator's default: the
# verified bitstream was built at 256 and a different depth is a
# different design. Raising it needs a rebuild and a re-measured skew.
python3 gen/receiver.py --board "$BOARD" --fifo-depth "$RX_FIFO"

echo "== ISP (revela pipeline, twin-verified before it emits)"
python3 gen/isp.py --width "$W" --height "$H" --bits "$BITS" \
    --clock-mhz "$ISP_MHZ"

echo "== display raster (np2hw scanout)"
python3 gen/scanout.py --mode "$MODE" --window "${W}x${H}"

echo "== implementation"
cd "boards/$BOARD"
vivado -mode batch -source bd.tcl
vivado -mode batch -source impl_a.tcl
vivado -mode batch -source impl_b.tcl

echo
echo "artifacts: boards/$BOARD/out/rx.bit and rx.hwh"
echo "NEXT: measure the scanout skew for THIS bitstream -- it is not"
echo "portable between builds. See the README, 'After the build'."
