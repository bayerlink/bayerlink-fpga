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
pip install np2hw
python3 gen/receiver.py --board pynq-z2 --width 512 --height 240
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
