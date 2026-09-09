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
pip install np2hw==0.6.1 bayerlink==0.5.0 revela==0.2.0
git clone --depth 1 https://github.com/Digilent/vivado-library.git
git clone --depth 1 https://github.com/xupsh/pynq-supported-board-file.git board-files
./build.sh                                 # -> boards/pynq-z2/out/rx.bit + .hwh
```

`build.sh` is the whole flow, and it exists because three of the four
sources are GENERATED and none of them is committed: the receiver, the
ISP and the display raster are emitted from their models, so a build
that skips a generator fails on a missing file rather than quietly
using a stale one. It runs:

```sh
python3 scripts/checkbd.py boards/pynq-z2/bd.tcl   # seconds here, not 20 minutes there
python3 scripts/checklicence.py

python3 gen/receiver.py --board pynq-z2   # -> hdl/generated/bayerlink_rx.v
python3 -m revela generate gen/pipeline.json --out hdl/generated --clock-mhz 155
python3 gen/scanout.py --board pynq-z2 --mode 1080p30 --genlock
python3 gen/tee.py                        # sized from the ISP's traced word
python3 gen/ddc.py

python3 gen/params.py  --board pynq-z2    # -> boards/<board>/generated/params.tcl
python3 gen/netlist.py --board pynq-z2    # -> boards/<board>/generated/netlist.tcl
python3 scripts/checknets.py boards/pynq-z2/bd.tcl

cd boards/pynq-z2 && vivado -mode batch -source bd.tcl
vivado -mode batch -source impl_a.tcl
vivado -mode batch -source impl_b.tcl

python3 scripts/checkhwh.py boards/pynq-z2/out/rx.hwh   # the design AS BUILT
```

The parameters and the datapath are generated too, and that is the point
of the ordering: `gen/params.py` runs AFTER the ISP because the ISP's
boundary is **traced**, so there is nothing to read until it has been
built. It reads three owners and no others -- the design
(`gen/pipeline.json`), the target (`board.json`) and the ISP's own
published contract -- and writes the single file `bd.tcl` sources.
`bd.tcl` reads no environment and declares no defaults: a fact nobody set
stops the build at once, rather than becoming a width mismatch that
Vivado downgrades to a warning and a picture that is quietly wrong.

The ISP is not scripted here: `gen/pipeline.json` is a revela pipeline
description -- named block instances and the connections between their
ports, nothing else -- and revela's generator builds it, proves it
bit-exact against its own NumPy models under Verilator, and refuses to
emit anything unverified. A failed build there is a verification
failure, not a tool problem. What this repo adds is `hdl/isp_shim.v`,
hand-shaped board glue: the header latch and the AXI4-Lite port,
wrapped around the pack.

### Timing margin, and what your build will and will not match

The design closes, but not with room to spare. Measured here on
xc7z020-1 with Vivado 2025.2: **WNS +0.003 to +0.020 ns** at 148.5 MHz
across the last few builds. A different Vivado, a different speed grade
or a different seed may miss, and the lever that matters is placement --
`place_design -directive ExtraTimingOpt` in `impl_a.tcl`. On one and the
same design, `Explore` gave +0.001 and `ExtraTimingOpt` gave +0.055; the
post-route physical-optimisation loop can only hand back what placement
left on the table.

Your bitstream will also not be byte-identical to the one in the demo
video. The depth model has moved since that recording, so one block cuts
into three pipeline stages where the filmed build used four. Both are
twin-verified bit-exact against the same NumPy models and both close --
the pixels are the same, the schedule is not.

### After the build: measure the write-side skew

One number may need measuring, and it is measured PER LOCK -- not per
bitstream, which is what this file used to claim. The displacement
seen on a screen was always the SUM of two rolls. The read half -- a
read engine whose start-of-frame marker travels ahead of its data --
is gone: `fbread` owns its addressing, so its first beat IS the
frame's first pixel. The write half remains: the write engine lands
each frame at an offset decided when the link comes up (values seen
on one unchanged bitstream: 0, 16, 48, 80), and `--skew` corrects it
at the framebuffer base address. Reloading the bitstream re-rolls it.
So does the source disappearing and returning.

That has a practical consequence: do not bisect it by reloading,
because every reload measures a different system. Measure once, and
compensate where the frames are consumed -- a grabbed frame carries
the offset; the reader that judges it corrects for it.

Measure it with the grabber and a known pattern: stream one of the
protocol's test patterns from the source (`scripts/mkpattern.py`
authors one AT YOUR PIPELINE'S OWN DEPTH, which is the depth in
gen/pipeline.json and nowhere else; a pattern authored at any other
depth is refused in a way that looks like a geometry fault and is not), `grab.py` a frame, and read the
roll off the known landmarks in the file. The display is direct and
never carries the offset; only grabbed frames do, and the reader
that judges them rolls it back. The compensation disappears
entirely when a fabric write engine replaces the vendor one.

Any Vivado from 2025.2 works, containerized included (if yours crashes
after "Routing Is Done", see the ledger: it is not your design).

### Porting to another board

Most of this design does not know what board it is on. The generated
sources take their shape from arguments, not from a part number, and
the ISP and the raster are proved against their models before they are
emitted. So a port is a short, finite list -- and it is worth knowing
exactly how short it is before you start:

| what | where | how you get it |
|---|---|---|
| pin assignments | `boards/<board>/<board>.xdc` | your board's master XDC |
| PS preset, DDR, HP ports | `boards/<board>/bd.tcl` | your board's preset or the vendor's own file |
| the lane map | `gen/receiver.py --board` | SOLVED, not guessed: `bayerlink.pattern counting`, then `checker` |
| the pixel clock | the link, not a choice | it is whatever your source sends |
| the write-side skew | measured per link lock | the grabbed-pattern recipe, above |

What you do NOT port: the receiver, the ISP and the raster themselves.
They are generated for your width, depth and video mode, and they are
timed by np2hw's traced depth model, which cuts each pipeline for the
clock you name. A different speed grade shifts that model, not the
design -- `np2hw.timing.FAMILIES` is where a device's constants live,
and adding one is a table entry.

The lane map deserves its own warning, because it is the one item that
LOOKS like a guess and must not be. It is a fact about a platform pair,
and the protocol carries test patterns precisely so it can be solved:
`counting` gives the fingerprint, and `checker` breaks the byte-0/1 tie
that counting cannot see. Guessing it produces a picture that is almost
right, which is worse than one that is obviously wrong.

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

The display side closes the loop on one board: np2hw's scanout — a
raster generator emitted from the one mode table, the header-parsing
receiver's counterpart — drives Digilent's rgb2dvi on HDMI OUT, fed
directly from the ISP stream. It arrives with the claims this bench
paid for: a frame may be dropped but never displaced, a window that
does not fit is refused rather than clipped, and pixel and enable
leave together. The picture is genlocked — the display clock follows
the sensor's rate through the MMCM's fine phase shifter while the
raster's geometry never moves — so latency to glass is lines, always:
there is no frame store in the picture path. Memory is an
*instrument*: a grabber captures frames to an address software chose,
for software to judge, and the display never depends on it.
Nothing runs the loop: power-on defaults enable the picture, so a
board with the bitstream loaded IS the camera's display -- software
is a set of visitors (`scripts/load.py` once at boot,
`scripts/status.py` when curious, `scripts/grab.py` to capture,
`scripts/calibrate.py` until parameters arrive over the cable from
the sensor's owner). `docs/clocking.md` tells the whole
clocks-and-rates story, end to end.

The ARM block was a placeholder, and it has been replaced:
`gen/pipeline.json` describes a revela pipeline -- black level, white
balance, Hamilton-Adams demosaic, colour matrix, tone curve -- and
revela generates it through np2hw, depth-checks every stage against
the clock (`--clock-mhz`; a too-deep stage is CUT into pipeline stages
by the traced depth model, and the one refusal left -- a single
operation deeper than the clock -- names itself), proves the
composition bit-exact against its own NumPy models under Verilator,
and only then emits Verilog. The whole ISP closes timing at the link's
148.5 MHz on the board's own clock. In the fabric it sits between
the receiver and the output tee; a control bit selects the stream's
consumer (the judge's capture path, or the ISP), and the ARM has no
standing job at all: pixels do not touch software, and neither does
the picture's survival. The camera is on the TV, in colour.

## The bring-up ledger

Lessons this repo already paid for, so you do not have to:

- The IN jack cannot transmit. A sink connector offers the display no
  +5V, so a picture driven out of it reaches nothing — proven with a
  pure-RTL colour-bar generator that had no software, no DMA and no
  stream to blame.
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
- A read engine whose start-of-frame marker travels ahead of its
  data cannot be compensated, only retired: the offset first looked
  constant per bitstream (306, 322, 338 here), then turned out to
  re-roll on every link lock. The reader that replaced it owns its
  addressing, so its first beat IS the frame's first pixel.
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
