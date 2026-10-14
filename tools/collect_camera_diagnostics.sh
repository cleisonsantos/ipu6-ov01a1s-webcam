#!/usr/bin/env bash
set -euo pipefail

timestamp="$(date +%Y%m%d-%H%M%S)"
out_dir="${1:-diagnostics/$timestamp}"

mkdir -p "$out_dir"

run_capture() {
    local name="$1"
    shift

    {
        echo "$ $*"
        echo
        "$@"
    } >"$out_dir/$name" 2>&1 || {
        local rc=$?
        {
            echo
            echo "command failed with exit code $rc"
        } >>"$out_dir/$name"
        return 0
    }
}

run_shell_capture() {
    local name="$1"
    local command="$2"

    {
        echo "$ $command"
        echo
        bash -lc "$command"
    } >"$out_dir/$name" 2>&1 || {
        local rc=$?
        {
            echo
            echo "command failed with exit code $rc"
        } >>"$out_dir/$name"
        return 0
    }
}

run_capture "lsusb.txt" lsusb
run_shell_capture "dmesg-camera-filter.txt" "dmesg | grep -Ei 'usb|uvc|video|v4l|webcam|camera|ipu|isys|cio2|csi|mipi' || true"
run_shell_capture "lsmod-camera-filter.txt" "lsmod | grep -Ei 'v4l2loopback|uvcvideo|videodev|mc|ipu|cio2|isys|camera|v4l' || true"
run_shell_capture "dev-video-media.txt" "ls -l /dev/video* /dev/media* 2>/dev/null || true"
run_shell_capture "firmware-ipu-files.txt" "find /lib/firmware -iname '*ipu6*' -o -iname '*ipu*' 2>/dev/null | sort || true"
run_shell_capture "dpkg-camera-packages.txt" "dpkg -l | grep -Ei 'ipu6|libcamera|v4l-utils|firmware-intel|firmware-linux' || true"
run_shell_capture "libcamera-ipa-dir.txt" "find /usr/lib -path '*libcamera*ipa*' -maxdepth 6 -print 2>/dev/null | sort || true"
run_shell_capture "kernel-camera-config.txt" "grep -E 'CONFIG_VIDEO_OV01A1S|CONFIG_VIDEO_OV01A10|CONFIG_VIDEO_OG01A1B|CONFIG_VIDEO_INTEL_IPU6|CONFIG_IPU_BRIDGE|CONFIG_INTEL_SKL_INT3472' /boot/config-\$(uname -r) || true"
run_shell_capture "kernel-camera-modules.txt" "find /lib/modules/\$(uname -r) -type f \\( -iname 'ov01a1s*' -o -iname 'ov01a10*' -o -iname 'og01a1b*' -o -iname 'intel-ipu6*' -o -iname '*ipu6*' \\) | sort || true"
run_shell_capture "kernel-camera-aliases.txt" "grep -Ei 'OVTI01AF|OVTI01AS|OVTI01A0|ov01a1s|ov01a10|og01a1b|ipu6' /lib/modules/\$(uname -r)/modules.alias /lib/modules/\$(uname -r)/modules.builtin.alias 2>/dev/null || true"
run_shell_capture "acpi-camera-devices.txt" "find /sys/bus/acpi/devices -maxdepth 1 -type l -printf '%f\\n' | sort | grep -Ei 'ov|imx|hi|gc|cam|ipu|int347|sensor' || true"
run_shell_capture "i2c-camera-devices.txt" "find /sys/bus/i2c/devices -maxdepth 2 -type l -printf '%p -> %l\\n' | sort | grep -Ei 'ov|imx|hi|gc|cam|sensor|ipu|int347' || true"

if command -v v4l2-ctl >/dev/null 2>&1; then
    run_capture "v4l2-list-devices.txt" v4l2-ctl --list-devices

    shopt -s nullglob
    for dev in /dev/video*; do
        base="$(basename "$dev")"
        run_capture "v4l2-device-${base}.txt" v4l2-ctl -D -d "$dev"
        run_capture "v4l2-formats-${base}.txt" v4l2-ctl --list-formats-ext -d "$dev"
        run_capture "v4l2-controls-${base}.txt" v4l2-ctl --list-ctrls -d "$dev"
    done
    shopt -u nullglob
else
    echo "v4l2-ctl not found. Install v4l-utils." >"$out_dir/v4l2-ctl-missing.txt"
fi

if command -v media-ctl >/dev/null 2>&1; then
    shopt -s nullglob
    for dev in /dev/media*; do
        base="$(basename "$dev")"
        run_capture "media-ctl-${base}.txt" media-ctl -p -d "$dev"
    done
    shopt -u nullglob
else
    echo "media-ctl not found. Install v4l-utils." >"$out_dir/media-ctl-missing.txt"
fi

if command -v libcamera-hello >/dev/null 2>&1; then
    run_capture "libcamera-list-cameras.txt" libcamera-hello --list-cameras
fi

if command -v cam >/dev/null 2>&1; then
    run_capture "libcamera-cam-list.txt" cam --list
    run_capture "libcamera-cam-version.txt" cam --version
elif ! command -v libcamera-hello >/dev/null 2>&1; then
    echo "cam not found. Install libcamera-tools if available for your distro." >"$out_dir/libcamera-cam-missing.txt"
else
    :
fi

run_shell_capture "pci-camera-filter.txt" "lspci -nnk | grep -Ei -A4 -B2 'ipu|camera|imaging|multimedia|media|isys' || true"

echo "Diagnostics written to: $out_dir"
