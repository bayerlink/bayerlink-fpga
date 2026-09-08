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
# A variant build is an EDIT to boards/<board>/design.json, not an
# environment variable: a different raster is a different design, and
# this way the bitstream corresponds to something you can diff.
#
# Needs: vivado on PATH, and the generators, PINNED:
#
#   pip install np2hw==0.6.0 bayerlink==0.5.0 revela==0.2.0
#
# Pinned rather than latest because this repository claims a REPRODUCIBLE
# demo: these are the versions the recorded bitstream was generated with,
# and they produce byte-identical Verilog. Newer ones may be better and
# will not be what was measured here.
# Also needs vivado-library/ and board-files/ beside this file; see the
# README for the two clone commands.
# WHICH BOARD is the only thing this script chooses. Everything else --
# the output raster, the clock the ISP is cut for, whether the capture
# path is built, the receiver's capacity -- is a property of a DESIGN,
# and lives in boards/<board>/design.json where it can be diffed. A
# shell default is not a record: it meant the bitstream on the bench
# corresponded to an environment nobody wrote down.
BOARD=${BOARD:-pynq-z2}
read_build() { python3 -c "import json,sys;print(json.load(open('boards/$BOARD/design.json'))['build'][sys.argv[1]])" "$1"; }
# The output raster. 1080p30 rides its own 74.25 MHz MMCM output and
# GENLOCKS: rate and phase follow the stream, fps flows through, and
# direct-to-glass is whole. 148.5-class modes (1080p60) free-run --
# the store path shows each frame twice, as a standard TV signal.
MODE=$(read_build mode)
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
ISP_MHZ=$(read_build isp_mhz)
RX_FIFO=$(read_build rx_fifo)
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
CAPTURE=$(read_build capture); [ "$CAPTURE" = "True" ] && CAPTURE=1 || CAPTURE=0

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
python3 scripts/checklicence.py

echo "== receiver (np2hw bayerlink_in)"
# --fifo-depth is PINNED, not left to the generator's default: the
# verified bitstream was built at 256 and a different depth is a
# different design.
python3 gen/receiver.py --board "$BOARD" --fifo-depth "$RX_FIFO" \
    --max-line-bytes "$(read_build max_line_bytes)" --bits "$BITS"

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
# No --window: the picture starts filling the mode's active area, and
# where it sits after that is WRITTEN, not built -- the raster's own
# geometry still comes from the mode table, its one owner. (The ISP's
# geometry is the design's, in gen/pipeline.json -- a different fact,
# deliberately independent: the ISP takes what the header brings at
# run time.)
python3 gen/scanout.py --board "$BOARD" --mode "$MODE" \
    $([ "$GENLOCK" = 1 ] && echo --genlock)

echo "== output tee (np2hw)"
python3 gen/tee.py
python3 gen/ddc.py

echo "== block design parameters, from the files that own them"
# The block design used to be told its numbers through the environment,
# with its own defaults beside each one in case it was not. Both are
# gone: gen/params.py reads the design, the board and the ISP's own
# published contract, and writes the single file bd.tcl sources. It runs
# HERE, after the ISP, because the ISP's boundary is traced rather than
# declared -- there is nothing to read until it has been built.
python3 gen/params.py --board "$BOARD"

echo "== pixel datapath (generated from design.json, widths checked)"
python3 gen/netlist.py --board "$BOARD"

# Every wire we draw between our OWN blocks, checked against the widths
# those blocks actually have -- with the parameters this build passes
# them. It runs HERE and not with the other structural checks because it
# needs the generated RTL and the parameters: there is nothing to
# measure until the blocks exist. np2hw refuses a mismatched edge inside
# a composed core; this is the same refusal for the edges outside one,
# where the block design would otherwise connect the low bits and issue
# a warning that looks like all the others.
python3 scripts/checknets.py "boards/$BOARD/bd.tcl"

echo "== implementation"
cd "boards/$BOARD"
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
