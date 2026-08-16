#!/usr/bin/env python3
# Copyright 2026 Serge Rabyking
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Generate the bayerlink receiver for one board and capacity.

The Verilog is NEVER committed: np2hw is its single source of truth,
and this script is the whole build step. Regenerate, don't edit.

The v2 receiver has no build-time geometry or depth: each frame's
header owns those. The build fixes capacity only.

    pip install np2hw bayerlink
    python3 gen/receiver.py --board pynq-z2
"""
import argparse
import json
from pathlib import Path

from np2hw.video_in import bayerlink_in

HERE = Path(__file__).resolve().parent.parent


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--board", required=True)
    parser.add_argument("--max-line-bytes", type=int, default=4096)
    parser.add_argument("--fifo-depth", type=int, default=1024)
    # The depth samples LEAVE at. The header still owns what the sensor
    # SENT; the receiver aligns it to this on the way out, so downstream
    # the depth is a build fact. Must be the ISP's --bits and the block
    # design's SW: build.sh owns the number and passes it to all three.
    parser.add_argument("--bits", type=int, default=10,
                        help="output depth; the ISP is built for this")
    args = parser.parse_args()

    board = json.loads(
        (HERE / "boards" / args.board / "board.json").read_text())
    result = bayerlink_in(
        max_line_bytes=args.max_line_bytes,
        fifo_depth=args.fifo_depth,
        module_name="bayerlink_rx",
        lane_map=tuple(board["lane_map"]),
        bits=args.bits)
    out = HERE / "hdl" / "generated"
    out.mkdir(exist_ok=True)
    (out / "bayerlink_rx.v").write_text(result["verilog"])
    print(f"generated hdl/generated/bayerlink_rx.v "
          f"(capacity {args.max_line_bytes} line bytes, all depths in, "
          f"{args.bits}-bit aligned out, "
          f"lane_map {tuple(board['lane_map'])}, {args.board})")


if __name__ == "__main__":
    main()
