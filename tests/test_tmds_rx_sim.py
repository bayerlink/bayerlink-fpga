# Copyright 2026 Serge Rabyking
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""tmds_rx, simulated against a TMDS source.

The source encodes as DVI does and skews its lanes by bits and by whole
words; the receiver must lock, align and bond them, deliver every pixel
of every line of every frame, let go of its lock when the cable is
pulled, and lock again when it returns with the skews changed -- at
1080p60's link, at half of it, where a bit is twice the taps, and at 480p's,
where a bit is longer than the whole delay line. The
7-series primitives are behavioural stand-ins (tests/sim/xilinx_models.v):
this proves the receiver's logic, and the bench proves the silicon.
"""
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
HDL = ROOT / "bayerlink_fpga" / "hdl"
SIM = ROOT / "tests" / "sim"


@pytest.mark.skipif(shutil.which("iverilog") is None, reason="needs iverilog")
@pytest.mark.parametrize("link", ["148.5", "74.25", "27"])
def test_the_receiver_delivers_every_pixel_and_relocks(tmp_path, link):
    sources = [SIM / "xilinx_models.v", SIM / "tb_tmds_rx.v"] + [
        HDL / f"tmds_{m}.v" for m in ("rx", "rx_lane", "align", "bond")]
    defines = {"74.25": ["-DLINK74"], "27": ["-DLINK27"]}.get(link, [])
    subprocess.run(["iverilog", "-g2012", *defines,
                    "-o", str(tmp_path / "sim.vvp"),
                    *map(str, sources)], check=True)
    run = subprocess.run(["vvp", str(tmp_path / "sim.vvp")], cwd=tmp_path,
                         capture_output=True, text=True, timeout=1200)
    assert "tmds_rx: PASS" in run.stdout, run.stdout[-3000:]
