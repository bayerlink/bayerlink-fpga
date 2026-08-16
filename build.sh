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
# Needs: vivado on PATH, and the generators, PINNED:
#
#   pip install np2hw==0.4.0 bayerlink==0.4.0 revela==0.1.0
#
# Pinned rather than latest because this repository claims a REPRODUCIBLE
# demo: these are the versions the recorded bitstream was generated with,
# and they produce byte-identical Verilog. Newer ones may be better and
# will not be what was measured here.
# Also needs vivado-library/ and board-files/ beside this file; see the
# README for the two clone commands.
BOARD=${BOARD:-pynq-z2}
MODE=${MODE:-1080p60}
W=${W:-1920}
H=${H:-1080}
BITS=${BITS:-10}
ISP_MHZ=${ISP_MHZ:-148.5}
RX_FIFO=${RX_FIFO:-256}
# Include the bring-up capture path? It writes received frames to DDR
# so the ARM can judge them against what the camera sent -- the tap
# that proved this link bit-exact -- and costs a DMA, a clock
# converter, an interconnect port and the switch that exists only
# because there are then two consumers. On for a bench build, off for
# a demo. Whether the board CAN is the board's to say, below.
CAPTURE=${CAPTURE:-1}

here=$(cd "$(dirname "$0")" && pwd)
cd "$here"

# A build choice met against a board fact: asking a board for a path it
# has no PS to host is a mistake worth naming, not silently dropping.
if [ "$CAPTURE" = "1" ]; then
    python3 - "$BOARD" <<'EOF' || exit 1
import json, sys, pathlib
board = sys.argv[1]
facts = json.loads(
    (pathlib.Path("boards") / board / "board.json").read_text())
if not facts.get("capture", False):
    sys.exit(f"CAPTURE=1 but board {board!r} does not offer a capture "
             f"path (board.json says capture is not available). Build "
             f"with CAPTURE=0.")
EOF
fi

echo "== receiver (np2hw bayerlink_in)"
# --fifo-depth is PINNED, not left to the generator's default: the
# verified bitstream was built at 256 and a different depth is a
# different design. Raising it needs a rebuild and a re-measured skew.
python3 gen/receiver.py --board "$BOARD" --fifo-depth "$RX_FIFO" \
    --bits "$BITS"

echo "== ISP (revela pipeline, twin-verified before it emits)"
python3 gen/isp.py --width "$W" --height "$H" --bits "$BITS" \
    --clock-mhz "$ISP_MHZ"

echo "== display raster (np2hw scanout)"
python3 gen/scanout.py --mode "$MODE" --window "${W}x${H}"

echo "== implementation"
cd "boards/$BOARD"
# Both build-time choices reach the block design the same way: the
# sample width for the glue's parameter, and whether to build the
# capture branch at all.
export BITS CAPTURE
vivado -mode batch -source bd.tcl
vivado -mode batch -source impl_a.tcl
vivado -mode batch -source impl_b.tcl

echo
echo "artifacts: boards/$BOARD/out/rx.bit and rx.hwh"
echo "NEXT: measure the scanout skew for THIS bitstream -- it is not"
echo "portable between builds. See the README, 'After the build'."
