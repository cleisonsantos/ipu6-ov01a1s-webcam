#!/usr/bin/env bash
set -euo pipefail

if ! command -v v4l2-ctl >/dev/null 2>&1; then
    echo "v4l2-ctl not found. Install v4l-utils." >&2
    exit 1
fi

shopt -s nullglob
devices=(/dev/video*)

if ((${#devices[@]} == 0)); then
    echo "No /dev/video* nodes found."
    exit 0
fi

echo "V4L2 device list:"
echo
v4l2-ctl --list-devices || true
echo
echo "Per-node capabilities:"
echo

for dev in "${devices[@]}"; do
    echo "== $dev =="
    v4l2-ctl -D -d "$dev" 2>&1 | sed 's/^/  /' || true
    echo
done

echo "Relevant media modules:"
lsmod | grep -Ei 'v4l2loopback|uvcvideo|videodev|mc|ipu|cio2|isys' || true
