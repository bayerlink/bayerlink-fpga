# Copyright 2026 Serge Rabyking
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""The bayerlink receiver: parallel video in, one sample per clock out.

The bayerlink protocol (github.com/bayerlink/bayerlink) carries packed raw
Bayer over a display link: line 0 of the active area is a header, every
following line holds one camera line of CSI-2 packed bytes, zero-padded to
the display width. An HDMI receiver (dvi2rgb and its kin) recovers the
parallel video -- pixel clock, data enable, vsync, 24 data bits -- and this
receiver turns that into np2hw's elastic stream: `valid/ready/data` with
`sof/eol/last` framing, one sample per beat.

DEPTH MEETS THE BUILD HERE. The header's depth is run-time and the
datapath's is not, so samples leave ALIGNED to the build's depth
(`bits`): a shallower source is shifted up with its top bits replicated
into what it vacated, so full scale stays full scale, and a deeper one
is shifted down, losing low bits rather than a picture. Downstream the
depth is a build fact again and every traced stage keeps its constants;
`hdr_bits` still reports what the sensor actually sent.

This is the protocol's version-2 receiver: the header is PARSED, in
hardware, and it is the single owner of every per-stream fact:

  DEPTH IS RUN-TIME   the fourcc names the packing (8/10/12/14/16-bit, the
      one CSI-2 rule at five depths); the unpack engine carries the whole
      table, so one build serves any sensor. There is no depth register --
      a register would be a second owner of a fact the header already
      states, and one fact with two owners is the bug.

  GEOMETRY IS RUN-TIME   width and height come from the header, per frame.
      The build fixes only CAPACITY (``max_line_bytes`` sizes the buffers);
      a header the silicon cannot honour is refused, visibly.

  REFUSAL IS THE API   a bad magic, an unknown fourcc, a width that
      misaligns its packing groups, a line that exceeds capacity: each
      refuses the FRAME (not the stream), latches a sticky code for
      software, and waits for the next header. Nothing is guessed.

Three facts of the link shape the datapath, as in v1:

  BYTES BURST FASTER THAN SAMPLES   a display pixel carries 3 payload
      bytes; at 12 bits that is 2 samples, at 16 bits 1.5. A byte FIFO
      deep enough for a full line absorbs the burst; the protocol's rate
      rule (camera width <= the display mode's total line slots) is the
      condition under which the line always drains before the next one.

  NO BACKPRESSURE UPSTREAM   video cannot be stalled, so a FIFO overflow
      is unavoidable data loss, and unobservable data loss is how a demo
      becomes a debugging season. `overflow` is STICKY until reset.

  LANES ARE A PERMUTATION   which memory byte of the container arrives on
      which 8-bit video lane depends on the scanout and the receiver;
      `lane_map` fixes the permutation at generation time -- resolved once
      per platform pair with a test pattern, not discovered per frame.

The header's CRC is NOT checked in fabric: the TMDS link either decodes a
byte or does not, and the magic plus fourcc table already reject the
plausible corruptions; hosts holding a raw tap can always run the
reference codec's full verification.

The receiver is a Verilog file, `bayerlink_fpga/hdl/bayerlink_in.v`: its
structure never varies, only its capacity, its output depth and the
link's lane order, which are module parameters. What it needs from the PROTOCOL --
the fourcc table and the magic -- is generated from the reference codec
(`pip install bayerlink`) as `bayerlink_formats` by `formats()`, so the
protocol tables have exactly one owner.

A design names the receiver as a leaf, `bayerlink_in`, and sets it: the
lane map and the vsync polarity are facts of the front end filling its
hdmi_rx block, assigned from there, and the design states capacity and
the depth samples leave at.
"""
from __future__ import annotations

from np2hw.ports import Pin, published
from np2hw.stream import (bundle_name, clock_attribute, reset_attribute,
                          stream_pins)



# depth code (3 bits, in hdr_bits order) -> bits: the unpack engine's
# table in bayerlink_in.v, which formats() writes the protocol's codes in.
_CODES = {8: 0, 10: 1, 12: 2, 14: 3, 16: 4}


def _pins() -> list:
    """bayerlink_in.v's ports, the list its interface publishes."""
    pins = [
        Pin("clk", "input", note="the recovered pixel clock",
            attribute=clock_attribute("clk", bundle_name("out"), "rst")),
        Pin("rst", "input", attribute=reset_attribute("rst")),
        Pin("diag_clear", "input", before=(
            "Clears the DIAGNOSTIC tallies below, and only those. It is",
            "separate from rst because rst is now the LINK's: a reset",
            "arrives on every cable drop, and a tally cleared by the",
            "event it exists to count is not a tally. This one means a",
            "person, or software, asking to start counting again.")),
        Pin("vid_de", "input", before=(
            "Parallel video from the HDMI/DVI receiver. No ready exists on",
            "this side: video cannot be stalled, only missed.")),
        Pin("vid_vsync", "input"),
        Pin("vid_data", "input", 24),
        *stream_pins("out", "out", "BITS", flags=("sof", "eol", "last"),
                     before=(
            "The elastic stream a generated core consumes. Samples are",
            "ALIGNED to BITS bits: whatever depth the header names,",
            "what leaves here is full scale at this build's depth.")),
    ]
    pins += [
        Pin("overflow", "output", reg=True, before=(
            "STICKY until reset: unobservable loss is a debugging season.",)),
        Pin("refused", "output", reg=True),
        Pin("refuse_code", "output", 3, reg=True,
            note=("1 magic, 2 fourcc, 3 group",
                  "alignment, 4 capacity, 5 zero")),
        Pin("hdr_bits", "output", 5, reg=True,
            before=("The last ACCEPTED header, for hosts to observe.",)),
        Pin("hdr_width", "output", 16, reg=True),
        Pin("hdr_height", "output", 16, reg=True),
        Pin("hdr_phase", "output", 2, reg=True),
        Pin("hdr_source_id", "output", 8, reg=True,
            note="WHICH camera sent it"),
        Pin("hdr_frame_seq", "output", 32, reg=True,
            note="WHICH frame it is"),
        Pin("resync_count", "output", 8, reg=True,
            note="stream restarts, wrapping"),
        Pin("hdr_valid", "output", reg=True),
    ]
    return pins


def formats() -> str:
    """`bayerlink_formats`: the protocol's fourcc table and magic, from the
    reference codec, as the combinational lookup bayerlink_in.v
    instantiates. Data, generated from its one owner."""
    from bayerlink.protocol import _FOURCC, BAYER_PHASE, MAGIC
    L = ["// generated by np2hw from bayerlink.protocol -- the fourcc table",
         "// and the magic of the reference codec, for bayerlink_in.",
         "module bayerlink_formats (",
         "    input  wire [31:0] fourcc,",
         "    output reg         known,",
         "    output reg  [2:0]  code,   // the unpack engine: 8/10/12/14/16",
         "    output reg  [1:0]  phase,  // the CFA phase",
         "    output wire [31:0] magic",
         ");",
         f"    assign magic = 32'h{MAGIC:08X};",
         "    always @* begin",
         "        known = 1'b1; code = 3'd0; phase = 2'd0;",
         "        case (fourcc)"]
    for text, (depth, order) in sorted(_FOURCC.items()):
        word = int.from_bytes(text.encode("ascii"), "little")
        L.append(f"            32'h{word:08X}: begin code = 3'd{_CODES[depth]}; "
                 f"phase = 2'd{BAYER_PHASE.get(order, 0)}; end "
                 f"// {text!r}: {depth}-bit {order or 'mono'}")
    L += ["            default: known = 1'b0;",
          "        endcase",
          "    end",
          "endmodule",
          ""]
    return "\n".join(L)


def bayerlink_in(max_line_bytes: int = 4096,
                 fifo_depth: int = 1024,
                 lane_map: tuple[int, int, int] = (0, 1, 2),
                 vsync_active_high: bool = True,
                 bits: int = 12) -> dict:
    """The version-2 receiver for one CAPACITY, any geometry or depth.

    Args:
        max_line_bytes: the largest packed camera line the buffers hold.
            A header whose ``width * bits / 8`` exceeds this is refused
            with a sticky code. Sizes the byte FIFO (one full line plus
            slack, in 3-byte words).
        fifo_depth: sample-side elastic, in samples, power of two, at
            least 16. Four banks so a whole emit batch lands in one cycle.
        lane_map: which video lane carries container byte 0, 1, 2. Lane 0
            is ``vid_data[23:16]``, lane 1 ``[15:8]``, lane 2 ``[7:0]``.
        vsync_active_high: polarity of the frame pulse.
        bits: the depth samples LEAVE at, and the width of the output
            stream. This is the build's, and it is the point of the
            argument: the header's depth is run-time and may be any of
            8/10/12/14/16, so a datapath built for one depth would
            otherwise be handed another. Each sample is aligned to full
            scale at ``bits`` on the way out -- a shallower source is
            shifted UP with its top bits replicated into the vacated low
            ones, so full scale stays full scale (8 into 12 maps 255 to
            4095, not 4080), and a deeper source is shifted DOWN, losing
            low bits rather than a picture. Downstream the depth is
            therefore a BUILD fact again, and every traced block keeps
            its constant. ``hdr_bits`` still reports what the sensor
            actually sent, because that is a different question.

    Returns:
        ``{"verilog", "module", "file", "parameters", "sources",
        "requires", "interface", ...}``: ``bayerlink_in`` is this
        package's file (``sources``), at the parameters this use sets; its
        output slice is np2hw's (``requires``); and ``verilog`` is what it
        needs generated -- ``bayerlink_formats``, the protocol's tables,
        in ``file``. A self-describing source module: no stream input, one
        ``bits``-wide output stream carrying full-scale-aligned samples.
        Sticky status: ``overflow``, ``refused`` + ``refuse_code``;
        observability: the last accepted header's
        ``hdr_bits/hdr_width/hdr_height/hdr_phase/hdr_valid``.
    """
    if max_line_bytes < 16:
        raise ValueError(f"max_line_bytes {max_line_bytes} is below any "
                         "real camera line")
    if sorted(lane_map) != [0, 1, 2]:
        raise ValueError(
            f"lane_map {lane_map} must be a permutation of (0, 1, 2)")
    if fifo_depth & (fifo_depth - 1) or fifo_depth < 16:
        raise ValueError(f"fifo_depth {fifo_depth} must be a power of two "
                         ">= 16 (four banks, batches of up to 4)")
    if not 1 <= bits <= 16:
        raise ValueError(
            f"bits {bits} outside 1..16: samples arrive in a 16-bit lane, "
            "and the output depth is what they are aligned to")
    parameters = {"MAX_LINE_BYTES": max_line_bytes, "FIFO_DEPTH": fifo_depth,
                  "BITS": bits, "LANE0": lane_map[0], "LANE1": lane_map[1],
                  "LANE2": lane_map[2],
                  "VSYNC_ACTIVE_HIGH": int(bool(vsync_active_high))}
    interface = {
        "clock": "clk",
        "reset": "rst",
        "param_prefix": "param_",
        "ports": published(_pins()),
        "parameters": parameters,
        # A SOURCE: no stream input (the video side is not an np2hw stream,
        # and cannot carry ready), one stream output.
        "input": None,
        "output": {"prefix": "out", "data_bits": bits,
                   "flags": ("sof", "eol", "last")},
        "streams": [{"prefix": "out", "direction": "out", "data_bits": bits,
                     "flags": ("sof", "eol", "last"), "domain": ""}],
        "params": [],
        # Stated, not assumed: nothing here is combinational, so a
        # consumer's first stage starts from a register and this module's
        # timing is its own. A composer that cannot see inside can still
        # read it, which is the point of saying it here and not in a
        # comment. (There is no `in_ready` to list: this is a source.)
        "combinational_outputs": (),
    }
    return {"verilog": formats(), "file": "bayerlink_formats.v",
            "module": "bayerlink_in", "parameters": parameters,
            # the receiver is this package's file, its output slice np2hw's
            "sources": ("bayerlink_fpga.hdl:bayerlink_in.v",),
            "requires": ("np2hw_skid",),
            "interface": interface, "max_line_bytes": max_line_bytes,
            "fifo_depth": fifo_depth, "lane_map": tuple(lane_map),
            "out_bits": bits, "depths": tuple(sorted(_CODES))}


# A leaf a design names (`bayerlink_fpga.receiver:bayerlink_in`) and sets:
# capacity and output depth from the design, the lane order and the vsync
# polarity from the front end's facts.
bayerlink_in.leaf = True
