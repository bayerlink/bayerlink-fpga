# bayerlink-fpga

**Raw sensor frames into an FPGA over HDMI — received, unpacked, judged.**

The receive side of [bayerlink](https://github.com/bayerlink/bayerlink) on
real boards: TMDS in, one raw Bayer sample per clock out, proven bit-exact
against the protocol's reference codec on the board's own ARM. The sibling
of [picam2hdmi](https://github.com/bayerlink/picam2hdmi) (the source
instrument) and [bayertap](https://github.com/bayerlink/bayertap) (the
receiver's toolbox on Linux).

The receiver core is **generated, not written**: `np2hw.video_in.
bayerlink_in()` emits it, held bit-exact against the reference codec in
simulation ([np2hw](https://github.com/lanserge/np2hw)). This repo adds
what any board needs around it, and nothing that belongs to one board
or design: the generic Verilog around the receiver, the TMDS front ends,
and the judgement harness that closes the loop on silicon.

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
  frontends/<name>/           cable to parallel video: frontend.json (the
                              lane map, vsync polarity) and frontend.tcl
                              (what its vendor IP needs at synthesis)
```

Every front end offers the same pins -- pixel clock, lock, data enable,
vsync, 24 data bits -- so neither the receiver nor a design above it
changes when the front end does. Nothing here knows a board: which front
end a board's jack uses, how it is configured there and which pins it
lands on belong to that board's own library, as one reusable block per
jack (revela's PYNQ-Z2 has `hdmi_in`), so every design on the board
shares it.

| front end | what | lane map | measured on |
|-----------|------|----------|-------------|
| `dvi2rgb` | Digilent's TMDS decoder on 7-series (ISERDESE2, IDELAYE2, MMCM) | (1, 2, 0) | PYNQ-Z2: 4/4 frames bit-exact, framing exact (2026-08-12) |

The lane map is a fact about a PLATFORM PAIR (scanout + receiver), solved
once with the protocol's test patterns: `counting` for the fingerprint,
`checker` to break the byte-0/1 tie that counting cannot see. It follows
the front end's bus order, so it lives with the front end; PYNQ-Z2 is
the only board it has been measured on. A new board with a known front
end needs pins and a judged capture; a new kind of HDMI input (a
receiver chip, another FPGA family) is a new front end -- see the
`sponsorable` label.

## Use it from a board design

```sh
pip install bayerlink-fpga
python3 -m bayerlink_fpga bayerlink_fpga.frontends.dvi2rgb --out <build dir> \
    --fifo-depth 256 --max-line-bytes 4096 --bits 12 --link-mode 1080p30
```

The build fixes capacity and the depth samples leave at, which the
design consuming them owns; the header owns everything else, per frame.
It writes the generated Verilog -- `bayerlink_rx.v`, `ddc_slave.v` -- and
the EDID it serves, `edid.bin`, to `<build dir>/hdl`, and `<build dir>/generated/receiver.tcl`, which a
synthesis run sources for `bayerlink_frontend_synth_prep <ip repo>`:
whatever the front end's vendor IP expects beside a batch run.

A design instantiates the receiver's modules by their blocks in
`modules.json` (`bayerlink_fpga.modules:bayerlink_rx` and the rest) and
wires them. revela's `revela/boards/pynq_z2` is the worked example: its
`hdmi_in.json` builds and configures the front end and pins the jack, and
its `pynq_demo.json` wires the receiver behind it.

## Judge

Build a design with the capture path in -- revela's PYNQ-Z2 design with
its `capture` parameter set to 1 in `pynq_demo.json` -- stream the
counting pattern at the receiver (picam2hdmi: `counting 512x240` at
`1280x720@60`), copy `rx.bit`, `rx.hwh` and the `gpio_layout.json` built
beside them, with `scripts/judge.py`, to the board (PYNQ image), and:

```sh
python3 judge.py --bit rx.bit --width 512 --height 240
```

Done means what it means everywhere in this ecosystem: every sample and
every framing flag equal to what the reference codec says, consecutively
(`--frames N` frames in a row, 4 by default). The judge reads every GPIO
field by name from that layout, and refuses one whose checksum, built
into the fabric, does not read back.

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

- dvi2rgb's `kClkRange` follows the clock CONSTRAINT (148.5 MHz on the
  PYNQ-Z2, as its base overlay ships), not the actual link rate.

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

- The receiver core generated at build time is **np2hw's output**, and
  np2hw's licence carries an Output Exception: what the tool writes
  into your design is not covered by np2hw's licence and may be used
  under any terms you choose. Nothing about your bitstream is
  encumbered by the generator.
- Pin locations belong to each board's own library: revela's PYNQ-Z2
  records them from the vendor's published master constraints, with
  provenance noted in the file.

bayerlink™ — the name asks one thing, see the protocol repo's
TRADEMARK.md.
