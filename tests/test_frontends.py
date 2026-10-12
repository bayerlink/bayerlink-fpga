# Copyright 2026 Serge Rabyking
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""The HDMI front end, set for the link it receives.

dvi2rgb's MMCM multiplies the link clock by 5 x kClkRange and divides by
kClkRange: the serial clock is the same whatever the range, which only
keeps the VCO inside its 600-1200 MHz specification. So the range is not a
board's choice but the link rate's consequence, and the front end works it
out from the rate it is given.
"""
import json

import pytest

from np2hw.design.composite import load

VCO_MHZ = (600, 1200)


def _front_end(tmp_path, monkeypatch, link_khz):
    package = tmp_path / f"jack_{link_khz}"
    package.mkdir()
    (package / "__init__.py").write_text("")
    (package / "lib.json").write_text(json.dumps({"blocks": {"top": {
        "nodes": {"rx": {"block": "bayerlink_fpga.frontends.hdmi_rx",
                         "build": {"link_khz": link_khz}}}}}}))
    monkeypatch.syspath_prepend(str(tmp_path))
    return load(f"{package.name}.lib:top", generate=False)


@pytest.mark.parametrize("link_khz", [148500, 74250, 54000, 40000, 27000,
                                      25200])
def test_the_range_keeps_the_vco_in_its_specification(tmp_path, monkeypatch,
                                                      link_khz):
    """1080p60, 1080p30/720p60, 480p's 27 MHz, VGA's 25.2: whatever the
    link, its range puts the VCO inside the part's specification."""
    rx = _front_end(tmp_path, monkeypatch, link_khz).instances["rx"]
    rng = int(rx.config["kClkRange"])
    vco = link_khz / 1000 * 5 * rng
    assert VCO_MHZ[0] <= vco <= VCO_MHZ[1], (link_khz, rng, vco)


def test_the_floor_is_the_implementations_fact(tmp_path, monkeypatch):
    """Below its slowest range the front end has none; it says where."""
    rx = _front_end(tmp_path, monkeypatch, 74250).instances["rx"]
    floor = rx.leaf["filled_by"]["chosen"]["facts"]["min_link_khz"]
    assert floor / 1000 * 5 * 5 >= VCO_MHZ[0]
