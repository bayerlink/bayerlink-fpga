#!/usr/bin/env python3
# Copyright 2026 Serge Rabyking
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Check every wire the block design draws between OUR OWN blocks.

np2hw checks this inside a composed core -- "a composer that does not
check this connects a 10-bit Bayer stream to a block built for 12-bit
RGB and emits Verilog that elaborates, which is the worst kind of
wrong". That check stops at the core's boundary. Everything outside it
is `connect_bd_net`, and a block design answers a width mismatch with a
CRITICAL WARNING and a silent connection of the low bits.

Every bug of that shape this repo has had lived in exactly that gap:

  the ISP's input port was written [9:0] and stayed right until the
  pipeline moved to 12 bits, at which point the receiver's top two bits
  were dropped and the picture was merely darker;

  the glue that packs RGB for the framebuffer was written [29:0] and
  would have read three wrong fields the moment the ISP traced 36;

  the identity word came to 35 bits into a 32-bit GPIO and had been
  saying so, in a warning nobody read, for weeks.

So the widths are compared before Vivado starts, from the two things
that actually know them: the module's own Verilog, with the parameters
the block design passes it, and the design's own connections.

    python3 scripts/checknets.py [boards/pynq-z2/bd.tcl]

Vendor IP is out of scope -- its ports are not in files here, and its
automation is doing real work. This is about the wires we draw.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
BUNDLE = ("valid", "ready", "data", "sof", "eol", "last")


def module_ports(text: str, name: str, params: dict) -> dict:
    """Port name -> width, for one module, with parameters resolved.

    Width expressions are evaluated with the module's own defaults
    overridden by whatever the block design set on the cell -- because a
    port is only as wide as the instance was told to make it.
    """
    m = re.search(r"^module\s+" + re.escape(name) + r"\s*(#\((.*?)\))?\s*\((.*?)\);",
                  text, re.S | re.M)
    if not m:
        return {}
    values = dict(params)
    for pname, expr in re.findall(r"parameter\s+(\w+)\s*=\s*([^,\n)]+)", m.group(2) or ""):
        values.setdefault(pname, expr.strip())
    ports = {}
    for direction, width, port in re.findall(
            r"(input|output|inout)\s+(?:wire|reg)?\s*(?:signed\s*)?"
            r"(\[[^\]]+\])?\s*(\w+)", m.group(3)):
        ports[port] = (direction, width_of(width, values))
    return ports


def width_of(spec: str | None, values: dict) -> int:
    """A [hi:lo] spec as a bit count, with parameters substituted."""
    if not spec:
        return 1
    inner = spec.strip()[1:-1]
    hi, _, lo = inner.partition(":")
    try:
        return int(evaluate(hi, values)) - int(evaluate(lo, values)) + 1
    except Exception:
        return -1                      # unresolvable: reported, never assumed


def evaluate(expr: str, values: dict, depth: int = 0) -> int:
    expr = expr.strip()
    if depth > 8:
        raise ValueError(f"parameter expression too deep: {expr}")
    for name, value in values.items():
        expr = re.sub(rf"\b{re.escape(name)}\b", f"({value})", expr)
    if re.search(r"[A-Za-z_]", expr):
        raise ValueError(f"unresolved parameter in {expr!r}")
    return eval(expr, {"__builtins__": {}}, {})            # digits and operators only


def tcl_values(tcl: str, params_tcl: str) -> dict:
    """Every `set name value` the scripts make, as a flat table."""
    values = {}
    for text in (params_tcl, tcl):
        for name, value in re.findall(r"^\s*set (\w+)\s+([^\[\n]+?)\s*$",
                                      text, re.M):
            values[name] = value.strip()
    # `set sample_bits $p_sample_bits` is one hop; follow the chain, so a
    # value that is itself a variable resolves to the number it names.
    for _ in range(8):
        moved = False
        for name, value in list(values.items()):
            if value.startswith("$") and value[1:] in values:
                values[name] = values[value[1:]]
                moved = True
        if not moved:
            break
    return values


def main(path: Path) -> int:
    # The datapath's cells and stream edges are GENERATED into
    # netlist.tcl and already checked as they were written; what remains
    # in bd.tcl is everything else. Both are read here, so this check
    # sees the whole design rather than half of it -- a checker that
    # silently finds no cells would pass forever.
    tcl = path.read_text()
    generated = path.parent / "generated" / "netlist.tcl"
    if generated.exists():
        tcl += "\n" + generated.read_text()
    params_file = path.parent / "generated" / "params.tcl"
    if not params_file.exists():
        print("checknets: params.tcl is missing -- run the generators first",
              file=sys.stderr)
        return 1
    scalars = tcl_values(tcl, params_file.read_text())

    # cell -> (module, tcl variable)
    cells, var_of = {}, {}
    for m in re.finditer(
            r"set (\w+) \[create_bd_cell -type module -reference (\w+) (\w+)\]", tcl):
        cells[m.group(3)] = m.group(2)
        var_of[m.group(1)] = m.group(3)

    # cell -> {PARAM: value}, from every set_property CONFIG.X <value> <cell>
    overrides: dict[str, dict] = {}
    for line in tcl.splitlines():
        m = re.search(r"CONFIG\.(\w+)\s+(\S+)\s+\$(\w+)\s*$", line.strip())
        if not m:
            continue
        cell = var_of.get(m.group(3))
        if not cell:
            continue
        value = m.group(2)
        if value.startswith("$"):
            value = scalars.get(value[1:], value)
        overrides.setdefault(cell, {})[m.group(1)] = value

    # module -> source text
    sources = {}
    for src in list((HERE / "hdl").glob("*.v")) + list((HERE / "hdl" / "generated").glob("*.v")):
        text = src.read_text()
        for name in re.findall(r"^module\s+(\w+)", text, re.M):
            sources[name] = text

    problems, checked = [], 0
    ports_of: dict[str, dict] = {}
    for cell, module in cells.items():
        if module not in sources:
            problems.append(f"{cell}: module {module} not found in hdl/")
            continue
        ports_of[cell] = module_ports(sources[module], module,
                                      overrides.get(cell, {}))

    def resolve(pin: str) -> str:
        """`$var/sig` and `cell/sig` both name the same pin."""
        cell, _, sig = pin.partition("/")
        if cell.startswith("$"):
            cell = var_of.get(cell[1:], cell)
        return f"{cell}/{sig}"

    # Explicit nets, plus the six-signal stream bundles the script writes
    # as a foreach -- those are the pixel path, so they are the ones that
    # matter most and would otherwise go unchecked.
    nets = [(a, b) for a, b in re.findall(
        r"connect_bd_net \[get_bd_pins ([\w/\$]+)\] \[get_bd_pins ([\w/\$]+)\]", tcl)
        # A pin ending in a loop variable belongs to a foreach body; it is
        # expanded below, where the signal names are known.
        if not (a.endswith("$s") or b.endswith("$s")
                or a.endswith("$f") or b.endswith("$f"))]
    for a, b in re.findall(
            r"foreach s \{valid ready data sof eol last\} \{\s*\n\s*"
            r"connect_bd_net \[get_bd_pins ([\w/\$]+)\$s\] "
            r"\[get_bd_pins ([\w/\$]+)\$s\]", tcl):
        nets += [(a + sig, b + sig) for sig in BUNDLE]

    for a, b in nets:
        pa, pb = resolve(a), resolve(b)
        ca, sa = pa.split("/", 1)
        cb, sb = pb.split("/", 1)
        if ca not in ports_of or cb not in ports_of:
            continue                      # one end is vendor IP: out of scope
        wa = ports_of[ca].get(sa)
        wb = ports_of[cb].get(sb)
        if wa is None or wb is None:
            problems.append(f"{pa} -> {pb}: no such port on "
                            f"{ca if wa is None else cb}")
            continue
        checked += 1
        if wa[1] == -1 or wb[1] == -1:
            problems.append(f"{pa} -> {pb}: width could not be resolved "
                            f"({wa[1]} vs {wb[1]})")
        elif wa[1] != wb[1]:
            problems.append(
                f"{pa} ({wa[1]} bits) -> {pb} ({wb[1]} bits): WIDTH MISMATCH."
                " A block design connects the low bits and calls it a"
                " warning; the symptom is a picture, not an error.")

    # And the domain each datapath block DECLARES against the clock it is
    # actually given. Without this the declaration is a comment: it would
    # keep saying "pixel" long after someone moved the block to the
    # island, and the composer's domain check would be checking fiction.
    import json as _json
    design_file = path.parent / "design.json"
    if design_file.exists():
        design = _json.loads(design_file.read_text())
        clock_of = {name: spec["clock"]
                    for name, spec in design.get("domains", {}).items()}
        driver = {}
        for src, dst in re.findall(
                r"connect_bd_net \[get_bd_pins ([\w/\$]+)\] "
                r"\[get_bd_pins ([\w/\$]+)/clk\]", tcl):
            driver[resolve(dst + "/x").split("/")[0]] = src
        for inst in design["instances"]:
            name, dom = inst["name"], inst.get("domain")
            if name not in ports_of or dom not in clock_of:
                continue
            got = driver.get(name)
            if got is None:
                problems.append(f"{name}: declares domain {dom!r} but nothing "
                                "drives its clk")
            elif got != clock_of[dom]:
                problems.append(
                    f"{name}: declares domain {dom!r} (clocked by "
                    f"{clock_of[dom]}) but its clk is driven by {got}")

    # THE WIDTH THE HARNESS CROPS AT IS THE WIDTH THE PACK WAS BUILT
    # WITH. One fact, and now one name -- but still two places, because
    # the pack's cores carry `WIDTH` as a generated default while the
    # pack's control wrapper takes no parameters, so the shim cannot pass
    # its value down and the two are related only by both descending from
    # the design's geometry. Crop at the wrong number and the picture is
    # sheared exactly as it would have been without any crop at all, so
    # the relation is asserted here rather than assumed.
    built = re.search(r"parameter\s+WIDTH\s*=\s*(\d+)",
                      sources.get("revela_isp_core", ""))
    told = overrides.get("isp", {}).get("WIDTH")
    if built and told is not None:
        if int(told) != int(built.group(1)):
            problems.append(
                f"the shim crops at WIDTH={told} but the pack was built "
                f"with WIDTH={built.group(1)}; a crop at the wrong width "
                "shears the picture exactly as no crop would")
    elif built and told is None:
        problems.append("the pack declares a built WIDTH but the shim is "
                        "never told it -- nothing would crop an over-wide "
                        "line")

    if problems:
        print(f"{path}: {len(problems)} problem(s)")
        for p in problems:
            print(f"  {p}")
        return 1
    print(f"  {path}: OK -- {checked} wires between our own blocks agree")
    return 0


if __name__ == "__main__":
    target = Path(sys.argv[1]) if len(sys.argv) > 1 else (
        HERE / "boards" / "pynq-z2" / "bd.tcl")
    sys.exit(main(target))
