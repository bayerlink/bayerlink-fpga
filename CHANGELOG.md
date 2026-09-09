# Changelog

Notable changes to bayerlink-fpga — the reference receiver on real
silicon: a TMDS front end, a generated ISP, and a display raster, on a
PYNQ-Z2.

This repository publishes no package. A tag here says which **generator
versions** the recorded bitstream was built from, because the claim it
makes is reproducibility: the pinned versions produce byte-identical
Verilog, and a build from anything else is a different design.

## 0.2.1

Built with `np2hw==0.6.1`, `bayerlink==0.5.0`, `revela==0.2.0`.

**The pinned install line resolves again.** 0.2.0 pinned `np2hw==0.6.0`,
which was withdrawn from PyPI before it was announced; a burned version
does not come back, so the documented `pip install` could not complete
and the reproducible build this repository promises was not reproducible
by anyone.

The same generator ships as np2hw 0.6.1. **The pin moved and the design
did not**: generating this pipeline under 0.6.0 and under 0.6.1 produces
a byte-identical pack — Verilog, register map, SystemRDL, FuseSoC core
and build manifest all compare equal. Between the two releases the only
code that changed is `ipxact.py`, which emits IP-XACT XML rather than
Verilog, plus one docstring. So the bitstream measured for 0.2.0 is the
bitstream this pin builds; nothing about the board result below is
restated on weaker evidence.

## 0.2.0

Built with `np2hw==0.6.0`, `bayerlink==0.5.0`, `revela==0.2.0`.

Measured on the board: **WNS +0.134 ns MET, WHS +0.050 ns**, TNS and THS
zero — more margin on both than 0.1.0 had. `rx.bit` and `rx.hwh`
written, the as-built audit passes on seven addressable slaves, and no
critical-warning class appears that an earlier build's log did not.

**And it ran.** Loaded on the PYNQ-Z2, the bridge restored fifty
registers over the display cable, the link locked and genlocked, and the
board produced a correct 1920x1080 picture from a live sensor — the
first tagged build here proven on glass in the same pass that built it.

### Line buffers moved behind a module boundary

np2hw 0.6.0 emits each line buffer as its own module rather than an
inline array, so an integrator targeting silicon can bind a memory macro
to it by name. On this board it is inert, and that is the point:
**block RAM 23.5 tiles (22 x RAMB36 + 3 x RAMB18), identical to the tile
against the previous build**, with LUTs and flip-flops within twenty of
where they were. A claim about inference that hardware could refute, and
did not.

### The RTL says what its ports are

Every AXI4-Lite port and every elastic-stream port now names the bus it
belongs to, and the block design is given the bus definition that makes
those names resolvable. `gen/netlist.py` reads those declarations
instead of matching port names with a regex — the grouping is stated by
the module that owns the ports rather than inferred by everything
downstream — and refuses a module that carries a handshake while
declaring nothing.

The six hand-written board modules that speak the protocol declare it
now. The emitted wiring is unchanged: `netlist.tcl` is byte-identical
across the whole change.

### The build says how much of the part it used

`report_utilization` runs after routing and lands beside the bitstream.
For its whole history this build reported whether it met timing and
never once how full the device was, which is not a question that can be
answered later.

### Known gaps

Unchanged from 0.1.0: nothing runs `sim/`, and the link-judge capture
path is off by default.

## 0.1.0 — first tagged build

Built with `np2hw==0.5.1`, `bayerlink==0.5.0`, `revela==0.2.0`.

Measured on the board: **WNS +0.047 ns MET, WHS +0.013 ns**, TNS and THS
zero, `rx.bit` and `rx.hwh` written, and no critical-warning class absent
from an earlier build's log.

### The design

- **Three of the four sources are generated and none is committed** — the
  receiver, the ISP and the display raster all come from their models.
  There is no hand-edited Verilog to drift, which is why a build that
  skips a generator fails on a missing file rather than quietly using a
  stale one.

- **The ISP is a description.** `gen/pipeline.json` says what the
  pipeline is, independent of any board; `revela` builds it and publishes
  what it traced. The last scripted pipeline is gone.

- **The block design's numbers are generated from the files that own
  them.** It used to learn them three ways — environment variables, Tcl
  defaults beside them, and constants in the script — which agreed until
  the depth moved and then did not. What a disagreement produces here is
  not an error but a picture, because Vivado answers a width mismatch
  with a CRITICAL WARNING and a silent connection of the low bits.

  Three owners now: `gen/pipeline.json` (the design), `board.json` (the
  target) and `<name>_build.json` (what the ISP actually traced, which
  nobody may restate). `bd.tcl` reads no environment and declares no
  defaults.

- **The datapath is described, not scripted.** `design.json` names the
  blocks, their widths and their connections; `gen/netlist.py` emits the
  Tcl and checks every width against the modules' own ports first. Every
  instance declares its clock domain, and an undeclared crossing is
  refused.

- **Two clock territories**: the cable's, quarantined because it stops
  when the cable is pulled, and the board's. Nothing addressable lives on
  a clock that can stop — a slave with no clock never answers, AXI has no
  timeout, and the first software access after that takes the processor
  with it.

- **Display placement is a register**, taken in vertical blanking behind
  an arm/ack handshake, so a frame is drawn with one coherent set or the
  previous one. A window that does not fit is refused rather than
  clipped.

- **A line wider than the pack was built for is cropped, not
  reinterpreted** — visibly, with a sticky `truncated`. A narrower
  picture can be recognised and tuned; a refused one is a black screen
  indistinguishable from a dead cable.

### Checks that run before Vivado does

`checkbd`, `checklicence` and `checknets` run in seconds, against twenty
minutes of synthesis. `checknets` compares every wire drawn between our
own blocks against the widths those blocks actually have — every bug of
that shape this repository has had lived in exactly that gap. `checkhwh`
then audits the design **as built**, because the intent and the
automation's result are different documents.

### Known gaps

- Nothing runs `sim/`: the four testbenches are launched by hand from a
  `// Run:` comment in each. Two had rotted unnoticed before this
  release and are fixed here.
- The link-judge capture path is off by default (`capture: false`); it is
  an episodic instrument, not a daily tax.
