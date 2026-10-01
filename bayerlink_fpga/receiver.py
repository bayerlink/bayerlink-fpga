# Copyright 2026 Serge Rabyking
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Generate the bayerlink receiver for one front end and capacity.

The Verilog is NEVER committed: np2hw is its single source of truth,
and this is the whole build step. Regenerate, don't edit.

The v2 receiver has no build-time geometry or depth: each frame's
header owns those. The build fixes capacity, and the depth samples
leave at -- which the design consuming them owns, never this file.
"""
from pathlib import Path


def generate(out: Path, *, lane_map, vsync_active_high: bool,
             fifo_depth: int, max_line_bytes: int, bits: int) -> str:
    """Write bayerlink_rx.v into `out`; return a one-line report."""
    from np2hw.video_in import bayerlink_in
    result = bayerlink_in(
        max_line_bytes=max_line_bytes,
        fifo_depth=fifo_depth,
        module_name="bayerlink_rx",
        lane_map=tuple(lane_map),
        vsync_active_high=vsync_active_high,
        bits=bits)
    out.mkdir(parents=True, exist_ok=True)
    (out / "bayerlink_rx.v").write_text(result["verilog"])
    return (f"bayerlink_rx.v (capacity {max_line_bytes} line bytes, all "
            f"depths in, {bits}-bit aligned out, lane_map "
            f"{tuple(lane_map)})")
