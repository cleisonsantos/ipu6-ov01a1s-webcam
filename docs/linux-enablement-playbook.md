# Linux enablement playbook

How to take a device that "doesn't work on Linux" and make it work, package it,
and publish it. This is the generalized method behind this repository
(the IPU6/OV01A1S webcam is the worked example).

## 1. Reconnaissance

Identify exactly what the hardware is before writing anything:

```bash
lspci -nnk                 # PCI devices + bound drivers
lsusb -tv                  # USB topology, interfaces, classes
lsusb -v -d VID:PID        # descriptors of a specific device
dmesg | grep -i <device>   # driver binding, firmware, errors
ls /sys/bus/acpi/devices/*/hid    # ACPI IDs (sensors, DPTF, hotkeys)
acpidump > acpi.dsl && iasl -d acpi.dsl   # firmware tables
```

Record: vendor/device IDs, ACPI HID, bus (USB / I2C / MIPI / PCI), Windows
driver name and package, firmware blobs, and what the vendor userspace stack
does.

## 2. Search before building

Most devices already have *something*. Check, in order:

1. Upstream Linux (newer kernel? config option? missing ACPI ID?).
2. The vendor's Linux stack (e.g. Intel `ipu6-drivers`, `ipu6-camera-hal`).
3. Community projects (GitHub, kernel lore, Debian/Ubuntu packages).
4. Distro quirks/DKMS packages.

The webcam case was 80% "missing ACPI ID + missing userspace stack", 20% glue.

## 3. Pick the integration layer

| Device class | Typical layer | Tools |
| --- | --- | --- |
| USB/HID peripheral (RGB, DAC, printer) | userspace daemon + udev | `hidraw`, `libusb`, `pyusb` |
| I2C/ACPI sensor (camera, touchpad) | kernel driver (DKMS) + ACPI mapping | kernel source, `ipu-bridge` style tables |
| PCI device (Wi-Fi, GPU) | kernel driver | hard; prefer upstream/vendor |
| Audio codec | kernel + userspace topology | SOF/ALSA UCM |
| Video pipeline | kernel + HAL/IPA | libcamera, vendor HAL |
| Thermal/fan (DPTF) | kernel driver or daemon | `intel_dptf`, `thermald` |

## 4. Reverse engineering toolbox

- **Windows driver analysis** — REA + Ghidra. Decompile the `.sys`/DLL, recover
  register tables, protocol structures, tuning blobs. See
  [`windows-driver-rea-findings.md`](windows-driver-rea-findings.md).
- **USB captures** — often faster than static RE for USB devices:
  - Windows: USBPcap + Wireshark, or a VM with USB passthrough.
  - Linux: `usbmon` + Wireshark (`modprobe usbmon`).
- **ACPI tables** — `acpidump`/`iasl` for firmware-configured devices
  (GPIO, I2C addresses, `_DSM` methods).
- **Vendor docs / leaked datasheets** — last resort, check licensing.

Keep an evidence log: what was observed vs. inferred, and the exact commands.

## 5. Implement and iterate

Small steps, verify each one:

```bash
# kernel: load module, check dmesg, media graph, sysfs
sudo modprobe <module>; dmesg | tail; media-ctl -p
# USB/HID: list devices, inspect reports
lsusb -v -d VID:PID; hidraw; evtest
# v4l2: formats, controls, capture
v4l2-ctl --list-devices; v4l2-ctl -d /dev/videoN --all
```

## 6. Package for users

- **DKMS** for kernel modules (survives kernel updates). Keep the patch small
  and regenerate from the distro's kernel source when possible.
- **Idempotent `install.sh`** + `uninstall.sh`.
- **udev rules** for device permissions; **systemd** units for daemons.
- **Secure Boot**: sign modules with an enrolled MOK, or document the tradeoff.
- **One-command usage** (`<device>-start`) and clear troubleshooting in README.

## 7. Publish and upstream

- Repo with README, GPL-2.0 (kernel code), docs, and the RE evidence.
- Never commit proprietary Windows binaries; document findings instead.
- Send the kernel-side fix upstream (`scripts/get_maintainer.pl`,
  `lore.kernel.org`). For the webcam that is the `OVTI01AF` ACPI ID patch.
- Keep the userspace workarounds documented while upstream catches up.

## 8. Legal and maintenance notes

- Kernel code is GPL-2.0; reverse-engineered *facts* (register values,
  protocols) are fine to document, but do not copy vendor code.
- Do not redistribute firmware/blobs unless their license allows it.
- Re-check DKMS modules after kernel updates; MOK enrollment must survive too.
- Bounded searches: record "not found" results so the next person doesn't
  repeat them.

## Candidate devices on this laptop

| Device | Status | Path |
| --- | --- | --- |
| Intel IPU6 + OV01A1S camera | done (this repo) | DKMS + Intel HAL/icamerasrc |
| ITE 8291 RGB keyboard (`048d:6007`) | no kernel driver | userspace `hidraw` daemon (`ite8291r3-ctl`) |
| DPTF (`ABCD0000`) fan/thermal | no driver bound | `intel_dptf`/`thermald` |
| Intel GNA / telemetry | not needed | — |
