#!/usr/bin/env python3
"""Minimal placeholder for future virtual-camera injection tooling."""

from __future__ import annotations

import argparse
import os
import sys


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Stub for future webcam frame injection into a v4l2loopback device."
    )
    parser.add_argument("--device", required=True, help="Target loopback node, e.g. /dev/video10")
    parser.add_argument("--width", type=int, default=640, help="Frame width")
    parser.add_argument("--height", type=int, default=480, help="Frame height")
    args = parser.parse_args()

    print(f"Target device: {args.device}")
    print(f"Requested size: {args.width}x{args.height}")

    if not os.path.exists(args.device):
        print("Device does not exist. Load v4l2loopback first.", file=sys.stderr)
        return 1

    print("This is a scaffold only.")
    print("Next step: implement a writer for YUYV/MJPEG frames into the loopback node.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
