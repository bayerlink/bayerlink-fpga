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
#   ./build.sh                       1080p30 out, genlocked, 1920x1080 ISP
#
# ISP_MHZ is the clock the pipeline is CUT for, and it must be the
# link's own pixel clock (148.5 for 1080p): the ISP rides the
# receiver's domain, so a lower number here would silently ask the
# generator for a pipeline too slow for the pixels arriving.
#   MODE=720p60 ./build.sh                (raster only; the ISP's
#                                            geometry is the design's)
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
# The output raster. 1080p30 rides its own 74.25 MHz MMCM output and
# GENLOCKS: rate and phase follow the stream, fps flows through, and
# direct-to-glass is whole. 148.5-class modes (1080p60) free-run --
# the store path shows each frame twice, as a standard TV signal.
MODE=${MODE:-1080p30}
# The ISP's geometry and depth belong to the DESIGN (gen/pipeline.json
# owns them); the receiver aligns samples to that depth, so BITS is
# READ from the description, never chosen here.
BITS=$(python3 -c 'import json; print(json.load(open("gen/pipeline.json"))["stream"]["bit_depth"])')
# 155, not 148.5: cutting for a few MHz more than the clock will run
# is what makes the cut placement DETERMINISTIC -- at exactly 148.5
# the estimator's 70ps of optimism decided whether a register moved,
# and builds swung +0.16 to -0.54 on nothing. Generation margin, the
# same idea as timing margin, one stage earlier. (Measured: +0.196
# MET, repeatably, on the build this default comes from.)
ISP_MHZ=${ISP_MHZ:-155}
RX_FIFO=${RX_FIFO:-256}
# Include the link-judge capture path? It snapshots what ARRIVED at
# the receiver, byte-exact, to compare against what was sent -- the
# tap that proved this link bit-exact, and the only tool that can
# convict a cable, a lane map or a receiver regression (the grabber
# taps AFTER the ISP and cannot substitute; the sender only ever
# knows what it sent). Its jobs are episodic -- board ports,
# receiver regressions, lane-map solving -- so it is OFF by
# default: it costs a DMA, a clock converter, an interconnect port,
# the consumer switch, and the thinnest timing path in the design.
# Whether the board CAN is the board's to say, below.
CAPTURE=${CAPTURE:-0}

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

# Twenty seconds here against twenty minutes there: Tcl reports a bad
# reference by running into it, after synthesising everything above.
echo "== block design checks"
python3 scripts/checkbd.py "boards/$BOARD/bd.tcl"

echo "== receiver (np2hw bayerlink_in)"
# --fifo-depth is PINNED, not left to the generator's default: the
# verified bitstream was built at 256 and a different depth is a
# different design.
python3 gen/receiver.py --board "$BOARD" --fifo-depth "$RX_FIFO" \
    --bits "$BITS"

echo "== ISP (revela pipeline, twin-verified before it emits)"
python3 -m revela generate gen/pipeline.json \
    --out hdl/generated --clock-mhz "$ISP_MHZ"

echo "== display raster (np2hw scanout)"
# The mode table is the one owner: the raster's pixel clock comes from
# it, and the block design is TOLD rather than left to agree by luck.
# 74.25-class modes genlock; 148.5-class free-run.
OUT_MHZ=$(python3 -c "from np2hw.video_out import mode_timing; \
print(mode_timing('$MODE')['pixel_mhz'])")
GENLOCK=$(python3 -c "print(1 if $OUT_MHZ < 100 else 0)")
export OUT_MHZ
python3 gen/scanout.py --mode "$MODE" --window "${W}x${H}" \
    $([ "$GENLOCK" = 1 ] && echo --genlock)

echo "== output tee (np2hw)"
python3 gen/tee.py
python3 gen/ddc.py

echo "== implementation"
cd "boards/$BOARD"
# Both build-time choices reach the block design the same way: the
# sample width for the glue's parameter, and whether to build the
# capture branch at all.
export BITS CAPTURE
vivado -mode batch -source bd.tcl
vivado -mode batch -source impl_a.tcl
vivado -mode batch -source impl_b.tcl

echo "== audit of the design AS BUILT"
# checkbd reads the intent; this reads what the automation and the
# polarity propagation actually did. Every rule in it is a board hang
# this bench already paid for once.
python3 "$here/scripts/checkhwh.py" "$here/boards/$BOARD/out/rx.hwh"

echo
echo "artifacts: boards/$BOARD/out/rx.bit and rx.hwh"
echo "NEXT: if the picture sits displaced, measure the write-side skew"
echo "-- it re-rolls per link lock. See the README, 'After the build'."
