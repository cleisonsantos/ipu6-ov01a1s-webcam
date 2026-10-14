#!/usr/bin/env bash
set -euo pipefail

if ! command -v lsusb >/dev/null 2>&1; then
    echo "lsusb not found. Install usbutils." >&2
    exit 1
fi

echo "Potential webcam or video-related USB devices:"
echo

lsusb | awk '
BEGIN { IGNORECASE=1 }
/(camera|webcam|video|imaging|uvc|capture|hd webcam)/ {
    print $0
    found = 1
}
END {
    if (!found) {
        print "No obvious webcam strings found in lsusb output."
        print "Inspect the full lsusb output and correlate with dmesg."
    }
}'
