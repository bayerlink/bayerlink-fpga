#!/usr/bin/env python3
# Copyright 2026 Serge Rabyking
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Emit the pixel datapath's cells and wires, from the design description.

The datapath used to be drawn by hand in Tcl, and hand-drawn wiring is
where every width bug in this repo has lived -- because a block design
answers a mismatch with a CRITICAL WARNING and a silent connection of
the low bits, so the symptom is a picture rather than an error.

So the datapath is DESCRIBED (design.json) and the Tcl is generated,
with the widths checked on the way through. An edge whose two ends
disagree stops the build here, named, before Vivado starts.

What this owns: our own blocks that carry the stream, the parameters
they are built at, and the stream edges between them.

What it deliberately does NOT own: clocks, resets, vendor IP and the
AXI automation. Those stay hand-written in bd.tcl -- a declarative
model of Vivado's interconnect automation would be a worse version of
something that already works, and the clock/reset discipline is audited
after the build by checkhwh.py, which reads what was actually produced.

    python3 gen/netlist.py --board pynq-z2

Writes boards/<board>/generated/netlist.tcl, which bd.tcl sources.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(HERE / "scripts"))
# The six signals an elastic stream is made of. Not an AXI-Stream and
# not a Xilinx interface -- there is no IP-XACT abstraction for it, which
# is why the block design wires it as six pins rather than one interface
# net. So a stream is RECOGNISED here rather than declared: a port prefix
# carrying all six is one, and a prefix carrying some of them is a
# mistake worth naming.
BUNDLE = ("valid", "ready", "data", "sof", "eol", "last")


def stream_groups(ports: dict) -> dict:
    """Every complete stream on a module, and which way it faces.

    The DIRECTION is the block's own testimony: on a sink, data arrives
    and ready leaves; on a source, the reverse. Reading it from the RTL
    rather than from the port's name is what lets an edge that joins two
    sources be refused -- a mistake no width check would ever see,
    because both ends would be the same width.
    """
    groups: dict = {}
    for name, (direction, width) in ports.items():
        m = re.match(r"(.+?)_(valid|ready|data|sof|eol|last)$", name)
        if m:
            groups.setdefault(m.group(1), {})[m.group(2)] = (direction, width)
    # The HANDSHAKE is what makes a stream. A port merely ending in
    # `_data` is not half a stream -- the receiver's parallel video input
    # is `vid_data`, `vid_de`, `vid_vsync`, and nothing about it is
    # elastic. So a prefix is a candidate only once it carries valid AND
    # ready, and a candidate missing any of the other four is the error
    # worth naming.
    candidates = {p: sig for p, sig in groups.items()
                  if {"valid", "ready"} <= set(sig)}
    out = {}
    for prefix, signals in candidates.items():
        if set(signals) != set(BUNDLE):
            continue                      # incomplete; reported by the caller
        data_dir = signals["data"][0]
        ready_dir = signals["ready"][0]
        if data_dir == "input" and ready_dir == "output":
            role = "sink"
        elif data_dir == "output" and ready_dir == "input":
            role = "source"
        else:
            role = "malformed"
        out[prefix] = {"role": role, "signals": signals,
                       "width": signals["data"][1]}
    return out, {p: sorted(sig) for p, sig in candidates.items()
                 if set(sig) != set(BUNDLE)}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--board", required=True)
    args = parser.parse_args()

    board_dir = HERE / "boards" / args.board
    design = json.loads((board_dir / "design.json").read_text())
    params_file = board_dir / "generated" / "params.tcl"
    if not params_file.exists():
        return fail("params.tcl is missing -- it is generated from the "
                    "design, the board and the ISP's contract, and this "
                    "netlist is built at the widths it names")

    from checknets import module_ports, tcl_values          # one resolver, shared

    scalars = tcl_values("", params_file.read_text())
    active = {"capture": scalars.get("p_capture") == "1",
              "genlock": scalars.get("p_genlock") == "1"}

    sources = {}
    for src in list((HERE / "hdl").glob("*.v")) + \
               list((HERE / "hdl" / "generated").glob("*.v")):
        text = src.read_text()
        for name in re.findall(r"^module\s+(\w+)", text, re.M):
            sources[name] = text

    # Resolve every instance's ports at the width it is built with, so
    # the edges below are checked against what will actually exist.
    ports, built, streams = {}, {}, {}
    for inst in design["instances"]:
        when = inst.get("when")
        if when and not active.get(when, False):
            continue
        module = inst["module"]
        if module not in sources:
            return fail(f"{inst['name']}: module {module} not found in hdl/")
        values = {}
        for pname, var in (inst.get("params") or {}).items():
            if var not in scalars:
                return fail(f"{inst['name']}.{pname} names {var}, which "
                            "params.tcl does not set")
            values[pname] = scalars[var]
        ports[inst["name"]] = module_ports(sources[module], module, values)
        streams[inst["name"]], partial = stream_groups(ports[inst["name"]])
        for prefix, signals in partial.items():
            return fail(f"{inst['name']} ({module}): port group {prefix!r} has "
                        f"{signals} -- a stream is all six of {list(BUNDLE)} or "
                        "it is not a stream, and a partial one is how a "
                        "ready or a last goes quietly missing")
        if "domain" not in inst:
            return fail(f"{inst['name']}: no clock domain declared. Which "
                        "clock a block runs on is the fact this board has "
                        "paid for three times; it is not optional here")
        built[inst["name"]] = inst

    lines = [
        "# GENERATED by gen/netlist.py from design.json -- do not edit.",
        "#",
        "# The pixel datapath: the blocks that carry the stream, the widths",
        "# they are built at, and the wires between them. Every width here",
        "# was checked against the modules' own ports before this file was",
        "# written; a mismatch is a refusal, not a warning.",
        "",
    ]
    # No `if {$capture}` here. The guards were resolved above, against
    # the same params.tcl the build uses, so this file contains exactly
    # the cells that exist -- guarding them a second time in Tcl would be
    # a second reading of the same fact, which is the shape of every bug
    # this whole arrangement exists to prevent.
    for name, inst in built.items():
        lines.append(f"# {inst['description']}")
        lines.append(f"set {inst['var']} [create_bd_cell -type module "
                     f"-reference {inst['module']} {name}]")
        for pname, var in (inst.get("params") or {}).items():
            lines.append(f"set_property CONFIG.{pname} ${var} ${inst['var']}")
        lines.append("")

    problems = []
    for edge in design["edges"]:
        guard = edge.get("when")
        if guard and not active.get(guard, False):
            continue
        src, dst = edge["from"], edge["to"]
        if src.startswith("@"):
            choice = edge["select"]
            key = next((k for k in choice if k != "default" and active.get(k)),
                       None)
            src = choice[key] if key else choice["default"]
        sc, _, sp = src.partition("/")
        dc, _, dp = dst.partition("/")
        if sc not in ports or dc not in ports:
            problems.append(f"{src} -> {dst}: {sc if sc not in ports else dc} "
                            "is not an instance of this datapath")
            continue
        a_grp, b_grp = streams[sc].get(sp), streams[dc].get(dp)
        if a_grp is None or b_grp is None:
            missing = src if a_grp is None else dst
            problems.append(f"{src} -> {dst}: {missing} is not a stream on "
                            "that block")
            continue
        # WHICH WAY EACH END FACES, from the RTL. Two sources joined are
        # the same width and would pass every width check ever written.
        if a_grp["role"] != "source" or b_grp["role"] != "sink":
            problems.append(
                f"{src} ({a_grp['role']}) -> {dst} ({b_grp['role']}): an edge "
                "runs from a source to a sink; this one does not")
        if a_grp["width"] != b_grp["width"]:
            problems.append(
                f"{src} ({a_grp['width']} bits) -> {dst} "
                f"({b_grp['width']} bits): WIDTH MISMATCH")
        # AND WHICH CLOCK EACH END RUNS ON. A stream handed straight from
        # one domain to another is not a wire, it is a metastability
        # generator with a picture attached; it needs a crossing, and the
        # edge has to say so.
        da, db = built[sc]["domain"], built[dc]["domain"]
        if da != db and not edge.get("crossing"):
            problems.append(
                f"{src} ({da}) -> {dst} ({db}): CLOCK DOMAINS DIFFER and the "
                "edge does not declare a crossing")
        pad = ""
        lines.append(f"# {src} -> {dst}"
                     + (f"  ({edge['description']})" if edge.get("description")
                        else ""))
        lines.append("foreach s {valid ready data sof eol last} {")
        lines.append(f"{pad}    connect_bd_net [get_bd_pins {src}_$s] "
                     f"[get_bd_pins {dst}_$s]")
        lines.append("}")
        lines.append("")

    if problems:
        print(f"gen/netlist.py: {len(problems)} problem(s)", file=sys.stderr)
        for p in problems:
            print(f"  {p}", file=sys.stderr)
        return 1

    out_dir = board_dir / "generated"
    out_dir.mkdir(exist_ok=True)
    (out_dir / "netlist.tcl").write_text("\n".join(lines))
    edges = sum(1 for e in design["edges"]
                if not (e.get("when") and not active.get(e["when"], False)))
    print(f"generated boards/{args.board}/generated/netlist.tcl -- "
          f"{len(built)} blocks, "
          f"{edges} stream edges, every width checked"
          + (" (capture)" if active["capture"] else ""))
    return 0


def fail(message: str) -> int:
    print(f"gen/netlist.py: {message}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
