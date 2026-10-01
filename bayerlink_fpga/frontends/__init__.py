# Copyright 2026 Serge Rabyking
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Front ends: what turns a cable into the receiver's parallel video.

One package each, holding frontend.json (the facts that follow from the
front end, such as the byte-lane map) and frontend.tcl (the block-design
procs that build it). Every front end offers the same pins -- pixel
clock, lock, data enable, vsync, 24 data bits -- so the receiver and the
designs above it do not change when it does.

How a front end is configured on a particular board, and which pins it
lands on, is that board's: a board names the front end by its module,
bayerlink_fpga.frontends.<name>, and passes its configuration.
"""
import importlib
import json
from pathlib import Path


def load(module: str) -> dict:
    """A front end's facts, plus its name and where its Tcl lives."""
    folder = Path(importlib.import_module(module).__file__).resolve().parent
    facts = json.loads((folder / "frontend.json").read_text())
    facts["name"] = folder.name
    facts["tcl"] = folder / "frontend.tcl"
    return facts
