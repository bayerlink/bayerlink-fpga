# Copyright 2026 Serge Rabyking
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""The receiver against the reference codec, and its ports against its file."""
import shutil
import sys
from pathlib import Path

import pytest
from np2hw.ports import elaborated_ports, resolve

from bayerlink_fpga.receiver import bayerlink_in

sys.path.insert(0, str(Path(__file__).parent))
import receiver_proof  # noqa: E402


@pytest.mark.skipif(shutil.which("iverilog") is None, reason="needs iverilog")
def test_the_receiver_meets_the_reference_codec():
    assert receiver_proof.main() == 0


@pytest.mark.skipif(shutil.which("verilator") is None,
                    reason="needs verilator")
@pytest.mark.parametrize("settings", [
    {"bits": 12},
    {"bits": 16, "lane_map": (1, 2, 0), "fifo_depth": 256},
    {"bits": 8, "max_line_bytes": 64, "fifo_depth": 16,
     "vsync_active_high": False},
])
def test_the_published_ports_are_the_files(settings):
    """Every port the interface publishes is the one the file elaborates
    to, at the parameters this use sets -- so a design wiring by the list
    wires the module."""
    core = bayerlink_in(**settings)
    want = {p["name"]: (p["direction"],
                        resolve(p["width"], core["parameters"]))
            for p in core["interface"]["ports"]}
    got = elaborated_ports(receiver_proof.sources(core), "bayerlink_in",
                           core["parameters"])
    assert want == got
