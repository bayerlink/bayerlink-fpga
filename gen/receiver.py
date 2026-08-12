#!/usr/bin/env python3
# Copyright 2026 Serge Rabyking
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Generate the bayerlink receiver for one board and geometry.

The Verilog is NEVER committed: np2hw is its single source of truth,
and this script is the whole build step. Regenerate, don't edit.

    pip install np2hw
    python3 gen/receiver.py --board pynq-z2 --width 512 --height 240
"""
import argparse
import json
from pathlib import Path

from np2hw.video_in import bayerlink_in

HERE = Path(__file__).resolve().parent.parent


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--board", required=True)
    parser.add_argument("--width", type=int, required=True)
    parser.add_argument("--height", type=int, required=True)
    args = parser.parse_args()

    board = json.loads(
        (HERE / "boards" / args.board / "board.json").read_text())
    result = bayerlink_in(
        cam_width=args.width, cam_height=args.height,
        module_name="bayerlink_rx",
        lane_map=tuple(board["lane_map"]))
    out = HERE / "hdl" / "generated"
    out.mkdir(exist_ok=True)
    (out / "bayerlink_rx.v").write_text(result["verilog"])
    print(f"generated hdl/generated/bayerlink_rx.v "
          f"({args.width}x{args.height}, lane_map "
          f"{tuple(board['lane_map'])}, {args.board})")


if __name__ == "__main__":
    main()
