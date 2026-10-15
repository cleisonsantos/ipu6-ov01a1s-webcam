# ipu6-ov01a1s-webcam

Enable the internal MIPI camera on Intel IPU6 (Tiger Lake) laptops with an
**OmniVision OV01A1S** sensor exposed by ACPI as `OVTI01AF`, using the
**hardware ISP** (Intel `ipu6-camera-hal` + `icamerasrc`) and publishing the
result to `/dev/video90` through `v4l2loopback`.

The result is a normal color camera that works in GNOME Camera, OBS, browsers
and meeting apps, with auto exposure, auto white balance and ISP denoising.

Tested on an **Avell B.ON** (Intel Tiger Lake / IPU6, Debian 14, kernel
`7.2.10+deb14-amd64`). The same approach should work on any IPU6 laptop whose
sensor is an OV01A1S behind ACPI `OVTI01AF`.

## Why this exists

The stock Linux stack does not support this machine out of the box:

1. `drivers/media/pci/intel/ipu-bridge.c` knows `OVTI01AS` but not `OVTI01AF`,
   so the sensor never gets a firmware-node graph and probe is deferred.
2. The `ov01a1s` sensor driver needs the matching ACPI ID.
3. The RGB-IR sensor needs the ISP + AIQ tuning pipeline; Debian's `libcamera`
   has no IPU6 IPA, so colors are unusable without Intel's userspace stack.

This project automates the whole fix and the userspace ISP setup.

## What the installer does

| Step | Action |
| --- | --- |
| 1 | Installs build dependencies (kernel headers/source, GStreamer dev, DKMS, ...) |
| 2 | Installs Intel `ipu6-drivers` as DKMS (provides the `ov01a1s` sensor driver) |
| 3 | Builds a patched `ipu-bridge` as **DKMS**, adding `OVTI01AF` (survives kernel updates) |
| 4 | Deploys `ipu6-camera-bins` (ISP/AIQ libraries) |
| 5 | Builds and installs `ipu6-camera-hal` (IPU6 hardware ISP HAL) |
| 6 | Builds and installs `icamerasrc` (GStreamer source element) |
| 7 | Fixes the HAL sensor profile for this board (OV01A1S is on CSI2 port **5**, upstream profile assumes 1) and grants `/dev/ipu-psys0` to the `video` group |
| 8 | Installs the `ipu6-webcam-start` command and a systemd user unit |

## Install

```bash
git clone https://github.com/cleisonsantos/ipu6-ov01a1s-webcam.git
cd ipu6-ov01a1s-webcam
sudo ./install.sh
sudo reboot
```

## Usage

```bash
ipu6-webcam-start
```

Then open your app and select **IPU6 ISP Camera (/dev/video90)**.

Options:

```bash
FLIP=no ipu6-webcam-start                 # disable the 180° rotation
WIDTH=640 HEIGHT=480 ipu6-webcam-start    # lower resolution
OUTPUT=/dev/video90 ipu6-webcam-start     # v4l2loopback node
```

To start automatically with the session:

```bash
systemctl --user enable --now ipu6-webcam
```

## Repository layout

```text
install.sh                      full installer (Debian/Ubuntu)
uninstall.sh                    removes DKMS/udev/launcher
dkms/ipu-bridge-ovti01af/       DKMS packaging for the patched ipu-bridge
systemd/ipu6-webcam.service     optional user service
tools/start_ipu6_isp_webcam.sh  ISP -> v4l2loopback launcher
tools/start_ipu6_webcam_meeting.sh
                                legacy userspace bridge (monochrome, no ISP)
src/ipu6_ba10_to_loopback.c     userspace RAW10 -> YUYV bridge (fallback)
patches/                        kernel patches for ipu-bridge / ov01a1s
docs/                           diagnostics, upstream report, RE findings
```

## Troubleshooting

**`icamerasrc` not found** — the plugin was not installed or built. Re-run
`sudo ./install.sh` or build `~/dev/icamerasrc-slim` (branch
`icamerasrc_slim_api`).

**Camera enumerates but no stream / `Input stream was missing`** — check the
HAL sensor profile:

```bash
grep availableSensors /etc/camera/ipu6/libcamhal_profile.xml
```

It must contain `ov01a1s-uf-5` (the CSI2 port of this board).

**`Failed to open PSYS, error: Permissão negada`** — the udev rule for
`/dev/ipu-psys0` is missing:

```bash
ls -l /dev/ipu-psys0     # should be root:video 0660
```

**Sensor not bound after a kernel update** — the DKMS modules are rebuilt
automatically, but the machine needs a reboot. Verify with:

```bash
readlink /sys/bus/i2c/devices/i2c-OVTI01AF:00/driver   # -> .../drivers/ov01a1s
media-ctl -p -d /dev/media0 | grep -A4 ov01a1s
```

**Camera works in OBS/Chrome but not in GNOME Snapshot** — GNOME uses
PipeWire/WirePlumber. There are three known issues:

1. The loopback must use `exclusive_caps=0` (see
   `/etc/modprobe.d/ipu6-webcam.conf`), otherwise udev marks it
   `:video_output:` only and WirePlumber ignores it.
2. The raw IPU6 nodes (`ipu6 (V4L2)`) should be hidden from the camera list:
   `sudo bash tools/fix_gnome_snapshot.sh`.
3. **PipeWire's SPA v4l2 plugin has a hard limit of 64 V4L2 devices**
   (`MAX_DEVICES` in `spa/plugins/v4l2/v4l2-udev.c`). The IPU6 driver creates
   64 `Intel IPU6 ISYS Capture` nodes, so `/dev/video90` is silently dropped
   and never appears in GNOME. Rebuild that plugin with a higher limit:

   ```bash
   tools/build_patched_spa_v4l2.sh
   ```

   The script compiles the plugin from the same PipeWire version and loads it
   through `SPA_PLUGIN_DIR` (user-level drop-ins), without touching system
   files.

After that, restart WirePlumber if needed:

```bash
systemctl --user restart wireplumber
```

**Image upside down** — use `FLIP=no`/`FLIP=yes` depending on your panel
rotation.

**Monochrome fallback (no ISP)** — if you only need a stable image without
color, the userspace bridge still works:

```bash
tools/start_ipu6_webcam_meeting.sh
```

## Reverse engineering notes

The Windows driver package for this sensor (`ov01a1s.sys`, AIQB tuning blobs,
graph settings) was analyzed with REA + Ghidra; the findings (register tables,
sensor modes, 60 fps timing, `YHRN180` flip handling) are documented in
[`docs/windows-driver-rea-findings.md`](docs/windows-driver-rea-findings.md).
These notes informed the sensor configuration used here.

## Credits

- [intel/ipu6-drivers](https://github.com/intel/ipu6-drivers),
  [intel/ipu6-camera-bins](https://github.com/intel/ipu6-camera-bins),
  [intel/ipu6-camera-hal](https://github.com/intel/ipu6-camera-hal),
  [intel/icamerasrc](https://github.com/intel/icamerasrc) — the upstream stack
  this project automates and patches for this board.
- Linux media subsystem — `ipu-bridge`, `ov01a1s`.

## License

GPL-2.0-only. See [LICENSE](LICENSE). The kernel patch is derived from the
Linux kernel (`drivers/media/pci/intel/ipu-bridge.c`).
