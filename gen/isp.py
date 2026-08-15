#!/usr/bin/env python3
# Copyright 2026 Serge Rabyking
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Generate the demo ISP: a revela pipeline, in fabric, in colour.

blacklevel -> whitebalance -> bilinear demosaic -> rgb_gamma, composed
by revela and generated through np2hw -- the same flow `revela run
--rtl` verifies against the NumPy model. The Verilog is NEVER
committed; regenerate, don't edit.

Parameters are BAKED as constants in a wrapper for this first fabric
ISP (the register/DDC path is designed, not yet built): the OV5647
pedestal, a plain indoor white balance, a 2.2 tone curve. The wrapper
is the only hand-shaped text, and it is generated too.

    pip install revela   (or the sibling checkout)
    python3 gen/isp.py --width 512 --height 240
"""
import argparse
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent

PEDESTAL = 16          # OV5647, 10-bit scale; measured 15 in the dark
# MEASURED here, from the slope of a ColorChecker's neutral ramp in this
# garden's light. White balance and the colour matrix do DIFFERENT jobs:
# the gains adapt to the ILLUMINANT (what an AWB loop would be doing
# continuously), the matrix corrects the SENSOR's filters and is fixed.
# The matrix assumes neutrals arrive already balanced -- its rows sum to
# 256, so it preserves whatever cast reaches it rather than removing one.
# The published generic gains under-corrected and left the picture green.
# Fitted from the RAMP, not one grey patch, because red carries an offset
# that does not scale with the light: IR past a weak cut filter.
WB = {"r": 491, "gr": 256, "gb": 256, "b": 305}   # Q8.8, this light
GAMMA = 2.2
# Identity in Q.8: the matrix is WIRED but not yet CHOSEN. The daylight
# set belongs with the pedestal and the white balance -- one coherent
# change, judged on a screen -- not slipped in beside a structural one.
# The PUBLISHED 5890 K calibration for this sensor, not the one this
# bench fitted. Ours came out with a 2.46x red diagonal because the
# chart was measured through 9% veiling glare, and on real foliage --
# which is violently IR-bright, and this module's IR-cut filter is weak
# -- that turned every leaf red. A lab calibration beats a contaminated
# one, and the failure mode is not visible on a chart.
CCM = [[547, -167, -124], [-124, 494, -115], [-34, -140, 431]]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--width", type=int, default=512)
    parser.add_argument("--height", type=int, default=240)
    parser.add_argument("--bits", type=int, default=10)
    parser.add_argument("--clock-mhz", type=float, default=148.5,
                        help="the ISP's clock: the receiver's pixel "
                             "clock, constrained at the fastest legal "
                             "link. Every pointwise stage is depth-"
                             "checked against it at generation time; a "
                             "too-deep stage is CUT into pipeline "
                             "stages there, by arithmetic on the "
                             "traced expression graph")
    args = parser.parse_args()

    from revela.blocks import registry
    from revela.compose import Pipeline
    from revela.host.curves import knots_from_curve
    from revela.stream import StreamSpec

    reg = registry()
    p = Pipeline("revela_isp_core",
                 StreamSpec(bit_depth=args.bits, channels=1),
                 args.width, args.height,
                 inputs=("isp_in",), outputs=("isp_out",))
    chain = [("bl", "blacklevel", None),
             ("wb", "whitebalance", None),
             ("hg", "ha_green", None),
             ("hr", "ha_rb", None),
             ("cc", "ccm", None),
             ("gm", "rgb_gamma", {"knots": {"bits": args.bits + 1}}),
             ("lg", "logo", None)]
    for name, kind, regs in chain:
        p.add(name, reg[kind], registers=regs)
    src = "isp_in"
    for name, kind, _ in chain:
        block = reg[kind]
        p.connect(src, f"{name}.{block.ports.inputs[0]}")
        src = f"{name}.{block.ports.outputs[0]}"
    p.connect(src, "isp_out")
    generated = p.generate(control=False, clk_ns=1000.0 / args.clock_mhz)
    print(f"timing: every pointwise stage fits "
          f"{1000.0 / args.clock_mhz:.1f} ns ({args.clock_mhz:g} MHz), "
          "by the traced depth model")

    # Generation and verification are ONE step: the same composition
    # runs under Verilator against the same NumPy models with the same
    # baked values, on a synthetic colour scene. An unverified pipeline
    # cannot reach a bitstream from here.
    import numpy as np
    from revela import run as runner
    values = {
        "hg": {},
        "hr": {},
        "cc": {f"m_{r}_{c}": CCM[r][c] for r in range(3) for c in range(3)},
        "lg": {},
        "bl": {f"offset_{pos}": -PEDESTAL
               for pos in ("0_0", "0_1", "1_0", "1_1")},
        "wb": {"gain_0_0": WB["r"], "gain_0_1": WB["gr"],
               "gain_1_0": WB["gb"], "gain_1_1": WB["b"]},
        "gm": {f"knots_{i}": int(k) for i, k in enumerate(
            knots_from_curve(lambda v: v ** (1.0 / GAMMA),
                             count=33, bit_depth=args.bits))},
    }
    context = {"bayer_phase": 2}
    rng = np.random.default_rng(20260813)
    frame = rng.integers(0, 1 << args.bits,
                         size=(args.height, args.width), dtype=np.uint16)
    chain = runner.pixel_chain(p, None, None)
    model = runner.run_model(chain, frame, values, context, args.bits)
    rtl = runner.run_rtl(chain, frame, values, context, args.bits)
    if not np.array_equal(model, rtl):
        raise SystemExit("the generated RTL DIFFERS from the model; "
                         "refusing to emit an unverified pipeline")
    print(f"twin: bit-exact with the model ({model.size} words)")

    knots = knots_from_curve(lambda v: v ** (1.0 / GAMMA),
                             count=33, bit_depth=args.bits)
    kw = args.bits + 1

    L = []
    a = L.append
    a("// generated by gen/isp.py -- constants wrapper around the revela")
    a("// pipeline core. Parameters are BAKED for the demo: pedestal "
      f"{PEDESTAL},")
    a(f"// WB Q8.8 {tuple(WB.values())}, CCM Q.8 {CCM}, "
      f"gamma {GAMMA} in 33 knots.")
    a("module revela_isp (")
    a("    input  wire        clk,")
    a("    input  wire        rst,")
    a("    // The header's facts, straight from the receiver: the stream")
    a("    // owns its geometry and phase; the build owns only maximums.")
    a("    // Latched as each frame's SOF enters, so a change lands on a")
    a("    // frame boundary -- the pend/active pattern, third outing.")
    a("    input  wire [15:0] hdr_width,")
    a("    input  wire [15:0] hdr_height,")
    a("    input  wire [1:0]  hdr_phase,")
    a("    input  wire [4:0]  hdr_bits,")
    a("    input  wire        in_valid,")
    a("    output wire        in_ready,")
    a("    input  wire [15:0] in_data,   // v2 receiver lane; low bits used")
    a("    input  wire        in_sof,")
    a("    input  wire        in_eol,")
    a("    input  wire        in_last,")
    a("    output wire        out_valid,")
    a("    input  wire        out_ready,")
    a("    output wire [29:0] out_data,  // R low, G mid, B high, 10b each")
    a("    output wire        out_sof,")
    a("    output wire        out_eol,")
    a("    output wire        out_last")
    a(");")
    a(f"    reg [15:0] ctx_w = 16'd{args.width};")
    a(f"    reg [15:0] ctx_h = 16'd{args.height};")
    a("    reg [1:0]  ctx_ph = 2'd2;")
    a(f"    reg [4:0]  ctx_bd = 5'd{args.bits};")
    a("    always @(posedge clk)")
    a("        if (in_valid && in_ready && in_sof) begin")
    a("            ctx_w  <= hdr_width;")
    a("            ctx_h  <= hdr_height;")
    a("            ctx_ph <= hdr_phase;")
    a("            ctx_bd <= hdr_bits;")
    a("        end")
    a("    revela_isp_core core (")
    a("        .clk(clk), .rst(rst),")
    a("        .ctx_width(ctx_w),")
    a("        .ctx_height(ctx_h),")
    a("        .ctx_window_x0(16'd0), .ctx_window_y0(16'd0),")
    a("        .ctx_window_x1(ctx_w), .ctx_window_y1(ctx_h),")
    a("        .ctx_bayer_phase(ctx_ph),")
    a("        .ctx_bit_depth(ctx_bd),")
    for pos, colour in (("0_0", "r"), ("0_1", "gr"), ("1_0", "gb"),
                        ("1_1", "b")):
        a(f"        .param_bl_offset_{pos}(-16'sd{PEDESTAL}),")
        a(f"        .param_wb_gain_{pos}(16'd{WB[colour]}),")
    for r in range(3):
        for c in range(3):
            v = CCM[r][c]
            sign = "-" if v < 0 else ""
            a(f"        .param_cc_m_{r}_{c}({sign}16'sd{abs(v)}),")
    for i, k in enumerate(knots):
        a(f"        .param_gm_knots_{i}({kw}'d{int(k)}),")
    a(f"        .isp_in_valid(in_valid), .isp_in_ready(in_ready),")
    a(f"        .isp_in_data(in_data[{args.bits - 1}:0]),")
    a("        .isp_in_sof(in_sof), .isp_in_eol(in_eol), "
      ".isp_in_last(in_last),")
    a("        .isp_out_valid(out_valid), .isp_out_ready(out_ready),")
    a("        .isp_out_data(out_data),")
    a("        .isp_out_sof(out_sof), .isp_out_eol(out_eol), "
      ".isp_out_last(out_last)")
    a("    );")
    a("endmodule")

    out = HERE / "hdl" / "generated"
    out.mkdir(exist_ok=True)
    text = "\n".join(t for _, t in generated.modules)
    (out / "revela_isp.v").write_text(text + "\n\n" + "\n".join(L) + "\n")
    print(f"generated hdl/generated/revela_isp.v "
          f"({args.width}x{args.height}@{args.bits}b, "
          f"{len(generated.modules)} core modules + constants wrapper)")


if __name__ == "__main__":
    main()
