# bayerlink-fpga

**Raw sensor frames into an FPGA over HDMI — received, unpacked, judged.**

The receive side of [bayerlink](https://github.com/bayerlink/bayerlink) on
real boards: TMDS in, one raw Bayer sample per clock out, proven bit-exact
against the protocol's reference codec on the board's own ARM. The sibling
of [picam2hdmi](https://github.com/bayerlink/picam2hdmi) (the source
instrument) and [bayertap](https://github.com/bayerlink/bayertap) (the
receiver's toolbox on Linux).

The receiver core is `bayerlink_fpga/hdl/bayerlink_in.v`, a Verilog file
sized by parameters; the protocol's tables it reads are generated from
the reference codec, so it restates none of them. `tests/` holds it
bit-exact against that codec in simulation (`pytest`, with iverilog and
Verilator on the path). Around it is what any board needs, and nothing
that belongs to one board or design: the generic Verilog around the
receiver, the TMDS front ends, and the judgement harness that closes the
loop on silicon.

Designs that USE the receiver live with those designs. The
[revela](https://github.com/lanserge/revela) ISP on a PYNQ-Z2 -- camera
in, colour picture out -- is `revela/boards/pynq_z2` there.

## The frontend contract

Anything that feeds an ISP from a video link meets the same contract, so
frontends are swappable (a MIPI CSI-2 frontend meets it identically when
it lands):

- one elastic output stream — `valid/ready`, one sample per beat,
  raster order, `sof/eol/last` framing exact;
- runtime geometry from context registers — one owner, no second copy;
- the video-source law: the link cannot be stalled, so the frontend
  carries the elastic FIFO and a **sticky, observable overflow** —
  unobservable loss is how demos lie;
- status over registers, refusal-first: the stream disagreeing with the
  configuration is reported, never silently adapted to.

## Two layers

```
bayerlink_fpga/
  receiver.py, ddc.py, hdl/   the receiver: bayerlink_in, the DDC slave
                              (its EDID and control port), link reset,
                              the capture path's AXIS dressing
  modules.json                that Verilog, one block per module, for a
                              design to instantiate (revela's library
                              format: its sources, parameters, interfaces)
  frontends/hdmi_rx.json      cable to parallel video: the block and its
                              implementations, each stating its lane map
                              and vsync polarity
```

Every implementation of `hdmi_rx` offers the block's ports -- pixel
clock, lock, data enable, syncs, 24 data bits -- so neither the receiver
nor a design above it changes when the implementation does. Nothing here knows a board: which front
end a board's jack uses, how it is configured there and which pins it
lands on belong to that board's own library, as one reusable block per
jack (revela's PYNQ-Z2 has `hdmi_in`), so every design on the board
shares it.

| implementation | what | lane map | measured on |
|-----------|------|----------|-------------|
| `dvi2rgb` | Digilent's TMDS decoder on 7-series (ISERDESE2, IDELAYE2, MMCM) | (1, 2, 0) | PYNQ-Z2: 4/4 frames bit-exact, framing exact (2026-08-12) |

The lane map is a fact about a PLATFORM PAIR (scanout + receiver), solved
once with the protocol's test patterns: `counting` for the fingerprint,
`checker` to break the byte-0/1 tie that counting cannot see. It follows
the implementation's bus order, so it is that implementation's fact;
PYNQ-Z2 is the only board it has been measured on. A new board with a
known implementation needs pins and a judged capture; a new kind of HDMI
input (a receiver chip, another FPGA family) is a new implementation of
`hdmi_rx` -- see the `sponsorable` label.

## Use it from a board design

A board's jack fills a node with `hdmi_rx`; a design names the receiver
and its DDC slave as leaves and sets them. The receiver's lane order and
vsync polarity are assigned from the front end's facts, its capacity and
output depth from the design's own settings:

```json
"front": {"block": "bayerlink_fpga.frontends.hdmi_rx",
          "build": {"implementation": "'dvi2rgb'"}},
"blrx":  {"block": "bayerlink_fpga.receiver:bayerlink_in",
          "build": {"lane_map": "front.lane_map",
                    "vsync_active_high": "front.vsync_active_high",
                    "fifo_depth": 256, "max_line_bytes": 4096, "bits": 12}},
"ddc":  {"block": "bayerlink_fpga.ddc:ddc_slave",
         "build": {"link_mode": "'1080p30'"}}
```

The build fixes capacity and the depth samples leave at, which the
design consuming them owns; the header owns everything else, per frame.
Each leaf publishes every port of its module, so the design is wired by
that list; the EDID the DDC slave serves is its own
ROM. The receiver's hand-written modules -- the link
reset and the capture path's AXIS dressing -- are blocks in
`modules.json`, each declaring its ports.

revela's `revela/boards/pynq_z2` is the worked example: its `hdmi_in.json`
fills and configures the front end, pins the jack and passes the front
end's facts on, and its
`pynq_demo.json` wires the receiver behind it.

## Judge

Build a design with the capture path in -- revela's PYNQ-Z2 design with
its `capture` parameter set to 1 in `pynq_demo.json` -- stream the
counting pattern at the receiver, in the mode its EDID offers (picam2hdmi:
`counting 512x240` in the design's link mode plus its header row,
`1920x1081@30` for revela's default), copy `rx.bit` and the
`gpio_layout.json`, `address_map.json` and `clocks.json` built beside it,
with `scripts/judge.py` and revela's `bench/load.py`, to the board (PYNQ
image), and:

```sh
python3 load.py --bit rx.bit
python3 judge.py --bit rx.bit --width 512 --height 240
```

The judge programs nothing: it judges the bitstream `load.py` loaded,
and the layout checksum is what says the two are the same build.

Done means what it means everywhere in this ecosystem: every sample and
every framing flag equal to what the reference codec says, consecutively
(`--frames N` frames in a row, 4 by default). The judge reads every GPIO
field by name from that layout, and refuses one whose checksum, built
into the fabric, does not read back; it finds every register through the
address map, since the design's own bus places them and the `.hwh` cannot
see where.

The receiver is the protocol's version 2: the header is parsed in
fabric and OWNS depth and geometry per frame — all five packed
families (8/10/12/14/16-bit), any geometry the capacity allows, no
rebuild, no registers to disagree with the stream. A header the build
cannot honour refuses that frame with a sticky code. The build fixes
capacity and output depth only; the receiver takes no width and no input
depth.

## The bring-up ledger

Lessons this repo already paid for, so you do not have to:

- The IN jack cannot transmit. A sink connector offers the display no
  +5V, so a picture driven out of it reaches nothing — proven with a
  pure-RTL colour-bar generator that had no software, no DMA and no
  stream to blame.

- An async-FIFO crossing initializes only when both sides reset while
  both clocks run. A link that appears after boot therefore needs a
  software reset owning the whole receive path — pulse it once, link up.

- Absent `tkeep` means all-bytes-invalid to an AXI DMA: it accepts the
  stream, writes none of it, and raises no error.

- dvi2rgb's `kClkRange` follows the link rate, and the front end works it
  out from the `link_khz` it is given: the range keeps the MMCM's VCO in
  its specification and changes nothing else, the serial clock being five
  times the link clock whatever it is. The board's base overlay runs range
  1 at 74.25 MHz, which puts the VCO at 371 MHz, below its floor, and makes
  the design constrain the link at 148.5 MHz so that design-rule checks
  pass; range 2 with the link constrained at its own 74.25 MHz receives
  30/30 frames bit-exact.

- Captures race a continuous stream: discard one packet to align on a
  frame boundary, then judge.

- Framing is decided at INGEST, where position is known, and travels
  as tags with the bytes. Framing derived by counting delivered
  samples turns one lossy stretch into every later frame misframed.

- Video does not pause while an observer naps: any host reader is
  bursty, overflow is a way of life, and ONE lost byte must never
  wedge the stream. The specific wedge: an orphan byte stub too small
  to emit, under a frame barrier waiting for an empty window. Flush
  the stub; it belongs to a dead frame by definition.

- Sentinel-fill every capture buffer (0xBEEF, not zeros). A DMA's
  length readback mid-stall reports the programmed value, and a page
  of untouched zeros reads exactly like a decoded black frame.

## Funding

Developed independently; recurring support via
[github.com/sponsors/lanserge](https://github.com/sponsors/lanserge), or
write first: **s.rabykin@gmail.com**. Sponsorable targets carry the
[`sponsorable` label](https://github.com/bayerlink/bayerlink-fpga/issues?q=label%3Asponsorable)
— boards to adopt, and the MIPI CSI-2 frontend. Scope is agreed in
writing before work starts; sponsored work lands here openly,
immediately — sponsorship buys ordering and named credit, not
exclusivity. The person behind it:
[serge.rabyking.com](https://serge.rabyking.com).

## Licence

**Apache-2.0 WITH SHL-2.1** (Solderpad): this repo contains hardware
description, and Solderpad is Apache with the definitions hardware
needs — "source" that synthesizes, rights that survive fabrication.
Same licence, same reasoning, as the rest of this ecosystem's RTL.

Two boundary facts worth knowing:

- The DDC slave generated at build time is **np2hw's output**, and
  np2hw's licence carries an Output Exception: what the tool writes
  into your design is not covered by np2hw's licence and may be used
  under any terms you choose. Nothing about your bitstream is
  encumbered by the generator.
- Pin locations belong to each board's own library: revela's PYNQ-Z2
  records them from the vendor's published master constraints, with
  provenance noted in the file.

bayerlink™ — the name asks one thing, see the protocol repo's
TRADEMARK.md.
