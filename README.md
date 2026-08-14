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
what a real board needs around it — the TMDS front end, per-board
constraints and byte-lane maps, a batch build flow, and the judgement
harness that closes the loop on silicon.

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

## Supported boards

| board   | part            | lane_map  | status |
|---------|-----------------|-----------|--------|
| PYNQ-Z2 | xc7z020clg400-1 | (1, 2, 0) | 4/4 frames bit-exact, framing exact (2026-08-12) |

The lane map is a fact about a PLATFORM PAIR (scanout + receiver), solved
once with the protocol's test patterns: `counting` for the fingerprint,
`checker` to break the byte-0/1 tie that counting cannot see. Adding a
board is constraints + a lane map + a judged capture — see the
`sponsorable` label.

## Build (PYNQ-Z2)

```sh
pip install np2hw bayerlink
python3 gen/receiver.py --board pynq-z2
git clone --depth 1 https://github.com/Digilent/vivado-library.git
git clone --depth 1 https://github.com/xupsh/pynq-supported-board-file.git board-files
cd boards/pynq-z2
vivado -mode batch -source bd.tcl
vivado -mode batch -source impl_a.tcl
vivado -mode batch -source impl_b.tcl      # -> out/rx.bit, out/rx.hwh
```

Any Vivado from 2025.2 works, containerized included (if yours crashes
after "Routing Is Done", see the ledger: it is not your design).

## Judge

Stream the counting pattern at the receiver (picam2hdmi:
`counting 512x240` at `1280x720@60`), copy `rx.bit`/`rx.hwh` and
`scripts/judge.py` to the board (PYNQ image), and:

```sh
python3 judge.py --bit rx.bit --width 512 --height 240
```

Done means what it means everywhere in this ecosystem: every sample and
every framing flag equal to what the reference codec says, consecutively.

The receiver is the protocol's version 2: the header is parsed in
fabric and OWNS depth and geometry per frame — all five packed
families (8/10/12/14/16-bit), any geometry the capacity allows, no
rebuild, no registers to disagree with the stream. A header the build
cannot honour refuses that frame with a sticky code. The build fixes
capacity only; `gen/receiver.py` takes no width and no depth.

## The loopback

The display side closes the loop on one board: a raster generator of
our own (`hdl/vid_push.v` — the header-parsing receiver's counterpart:
it OWNS the 720p timing and pops one framebuffer pixel per active
clock) drives Digilent's rgb2dvi on HDMI OUT, fed by a VDMA
framebuffer. `scripts/display.py` runs the gray demo: camera in on
one HDMI, a one-block ISP on the ARM (shift to 8 bits, gray), live
picture out the other HDMI.

The ARM block was a placeholder, and it has been replaced: `gen/isp.py`
composes a revela pipeline -- black level, white balance, bilinear
demosaic, tone curve -- generates it through np2hw, depth-checks every
stage against the clock (`--clock-mhz`; a too-deep stage is CUT into
pipeline stages by the traced depth model, and the one refusal left --
a single operation deeper than the clock -- names itself), proves the
composition bit-exact against its own NumPy model under Verilator, and
only then emits Verilog. The whole ISP closes timing at the link's
148.5 MHz in the receiver's own clock domain: no clock island, no
clock converter, one clock from TMDS decode to framebuffer write. In the fabric it
sits between the receiver and the framebuffer's write channel; a
control bit selects the stream's consumer (the judge's capture path,
or the ISP), and `scripts/isp.py` is the ARM's entire remaining job:
point two VDMA channels at one buffer, flip the bit, report status.
Pixels do not touch software. The camera is on the TV, in colour.

`boards/pynq-z2/tpg_top.v` (+ `tpg_rtl.tcl`) is the port prover kept
as a diagnostic: pure-RTL colour bars out of BOTH HDMI jacks, no PS
software, no DMA — if a display shows bars, everything below the
stream layer is exonerated. It is also how this repo learned that the
IN jack cannot transmit: a sink connector offers the display no +5V.

## The bring-up ledger

Lessons this repo already paid for, so you do not have to:

- A floating ENABLE is a disable; a floating ARESETN is a permanent
  reset. Block designs tie silence to zero — audit every control input.
- Never `catch` a connect. A swallowed wiring error costs a bench
  iteration; a loud one costs two minutes.
- An async-FIFO crossing initializes only when both sides reset while
  both clocks run. A link that appears after boot therefore needs a
  software reset owning the whole receive path — pulse it once, link up.
- Absent `tkeep` means all-bytes-invalid to an AXI DMA: it accepts the
  stream, writes none of it, and raises no error.
- Design automation can leave a DMA's interconnect master unconnected
  and call it a warning. Wire one interconnect explicitly; pin address
  segments explicitly.
- dvi2rgb's `kClkRange` follows the clock CONSTRAINT (148.5 MHz here, as
  the board's base overlay ships), not the actual link rate.
- Captures race a continuous stream: discard one packet to align on a
  frame boundary, then judge.
- Vivado in containers: the post-route abort is webtalk's libudev
  enumeration corrupting the heap. Stub `libudev.so.1` (empty answers)
  and it never happens again.
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
- At 148.5 MHz, memories decide timing: a combinational read of a
  deep FIFO is a thousand-LUT mux (register the read, let it be block
  RAM), and a wide distributed bank's write fan-out is a net you can
  see from orbit (keep banks shallow, stage the write).
- A clocking wizard fed from FCLK needs `PRIM_SOURCE No_buffer`; the
  default builds an input path to a package pin that is not there,
  and the MMCM never sees an edge. Perfectly silent.
- The transmit recipe that lights displays: your own MMCM making the
  exact pixel clock, rgb2dvi generating its serial clock from it
  (MMCM, range 2), held in reset by nothing but the pixel MMCM's own
  lock. Clock quality IS the product: "TPG started!" with a black
  screen is an undecodable TMDS spectrum, not a missing enable.
- An IP block whose lock you cannot explain is replaceable. The
  timing controller pair here never locked under any documented
  configuration; a raster of our own is 90 lines, and every decision
  it makes is a status bit.
- A DMA writer must not outlive its buffer. A freed framebuffer is
  the kernel's to hand to anyone, and a VDMA still writing it sixty
  times a second corrupts page cache and, through writeback, the SD
  card underneath. Two "dying" cards were this one bug. Halt the
  write channel in every exit path; the read side may keep the
  picture -- reads hurt nobody.
- A warm reboot does not clear the PL. Halt fabric DMA writers
  BEFORE rebooting (one devmem poke), or the new kernel boots under
  fire from the old design.
- A clock island is a workaround, not an architecture. With the
  compiler placing pipeline registers from its traced depth model,
  the ISP rides the receiver's clock and the island retires.
- The last picoseconds belong to the tools: escalate post-route
  phys_opt, then reseed placement (Explore). An RTL fix below a
  hundred picoseconds of WNS is chasing placement noise.
- A raster must not start a frame on faith. If the read engine has
  not delivered that frame's first beat when active video begins,
  starting anyway paints the WHOLE frame displaced by the gap -- and
  no audit downstream can see it, because a beat that has not
  arrived carries no evidence. Arm per frame: a frame may be
  dropped, never displaced.
- The AXI VDMA's MM2S data lags its own start-of-frame marker by a
  fixed number of beats, constant for a bitstream and different
  between bitstreams (306, 322, 338 here). It does NOT depend on the
  buffer's address. Advance the read by the measured amount and give
  the buffer a spare line.
- When a picture is in the wrong place, bisect before theorising: a
  raster that paints from its OWN counters, ignoring the stream,
  separates "my timing is wrong" from "the data arrives wrong" in
  one build. Hours of hardware guessing did not.
- A reader must not outlive its buffer either. It corrupts nothing,
  but it faithfully displays whatever the kernel puts in those
  pages, which looks exactly like broken hardware.

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
- Pin locations in the constraints are facts of the board, recorded
  from the vendor's published master constraints; provenance is noted
  in the file.

bayerlink™ — the name asks one thing, see the protocol repo's
TRADEMARK.md.
