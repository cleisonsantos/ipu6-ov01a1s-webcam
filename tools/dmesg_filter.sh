#!/usr/bin/env bash
set -euo pipefail

if ! command -v dmesg >/dev/null 2>&1; then
    echo "dmesg not found." >&2
    exit 1
fi

dmesg | grep -Ei 'usb|uvc|video|v4l|webcam|camera' || true
