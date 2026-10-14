# Debian/kernel reporting steps for Intel IPU6 + OV01A1S webcam

This is the practical reporting flow for the webcam issue only.

## What to report

Report the kernel-side enablement bug first:

```text
Intel IPU6 OV01A1S camera needs OVTI01AF ACPI ID support
```

Keep this separate from audio, touchpad, and image-quality tuning. The most
actionable kernel issue is that the internal camera sensor is exposed by ACPI
as `OVTI01AF:00`, but the stock kernel path does not fully match/connect it.

The expected result of the proposed fix is enumeration and raw capture:

```text
cam --list
1: 'ov01a1s' (\_SB_.PC00.LNK0)
```

Good color/image quality is a second problem. That depends on RGB-IR handling,
ISP/libcamera tuning, and possibly OEM calibration data. Mention it as a
remaining limitation, but do not make it the primary bug.

## Files to attach or quote

Attach these project files:

```text
docs/upstream-report-ov01a1s-ovti01af.md
patches/linux-ipu6-ov01a1s-ovti01af.patch
```

Do not attach proprietary Windows binaries or calibration blobs. It is fine to
quote the relevant text from the Windows `.inf` and `.xml` files:

```text
ACPI\OVTI01AF
sensor_type="RGB_IR"
bayer_order="GRGB_IGIG_GBGR_IGIG"
bayer_order="GIGI_RGBG_GIGI_BGRG"
```

## Collect fresh diagnostics

Run this from the Debian system where the camera is being tested:

```bash
mkdir -p ~/dev/webcam/diagnostics/report

uname -a > ~/dev/webcam/diagnostics/report/uname.txt
cat /proc/version > ~/dev/webcam/diagnostics/report/proc-version.txt
hostnamectl > ~/dev/webcam/diagnostics/report/hostnamectl.txt
dpkg-query -W 'linux-image*' 'linux-headers*' > ~/dev/webcam/diagnostics/report/kernel-packages.txt
lspci -nnk > ~/dev/webcam/diagnostics/report/lspci-nnk.txt
lsmod > ~/dev/webcam/diagnostics/report/lsmod.txt
sudo dmesg > ~/dev/webcam/diagnostics/report/dmesg.txt
media-ctl -p -d /dev/media0 > ~/dev/webcam/diagnostics/report/media-ctl.txt 2>&1
cam --list > ~/dev/webcam/diagnostics/report/cam-list.txt 2>&1
v4l2-ctl --list-devices > ~/dev/webcam/diagnostics/report/v4l2-list-devices.txt 2>&1
v4l2-ctl -d /dev/video40 --get-fmt-video > ~/dev/webcam/diagnostics/report/video40-format.txt 2>&1
v4l2-ctl -d /dev/video40 --list-formats-ext > ~/dev/webcam/diagnostics/report/video40-formats-ext.txt 2>&1
v4l2-ctl -d /dev/v4l-subdev8 --list-ctrls > ~/dev/webcam/diagnostics/report/ov01a1s-controls.txt 2>&1
```

If any command fails, keep the generated file anyway. A failure message is also
useful evidence.

Find the exact Debian package for the running kernel:

```bash
dpkg-query -S /boot/vmlinuz-$(uname -r)
```

## Check for existing reports

Before filing a new Debian bug, search:

```text
https://bugs.debian.org/src:linux
https://bugs.debian.org/cgi-bin/pkgreport.cgi?src=linux
https://lore.kernel.org/linux-media/
```

Search terms:

```text
OVTI01AF
OV01A1S
ipu6 OVTI01AF
ipu-bridge OVTI01AF
Intel IPU6 OV01A1S
```

If an existing report matches, reply there instead of opening a duplicate.

## File the Debian bug

Install `reportbug` if needed:

```bash
sudo apt update
sudo apt install reportbug
```

Recommended command:

```bash
KPKG=$(dpkg-query -S /boot/vmlinuz-$(uname -r) | cut -d: -f1)
reportbug "$KPKG"
```

If that does not work, use:

```bash
reportbug src:linux
```

Use this subject:

```text
Intel IPU6 OV01A1S camera needs OVTI01AF ACPI ID in ipu-bridge
```

Use severity:

```text
important
```

Reason: Debian kernel policy includes lack of support for generally available
new hardware under `important`. If `reportbug` or the maintainer downgrades it,
that is fine.

In the report body, paste the content of:

```text
docs/upstream-report-ov01a1s-ovti01af.md
```

Then attach:

```text
patches/linux-ipu6-ov01a1s-ovti01af.patch
diagnostics/report/uname.txt
diagnostics/report/kernel-packages.txt
diagnostics/report/lspci-nnk.txt
diagnostics/report/dmesg.txt
diagnostics/report/media-ctl.txt
diagnostics/report/cam-list.txt
diagnostics/report/video40-format.txt
diagnostics/report/video40-formats-ext.txt
diagnostics/report/ov01a1s-controls.txt
```

## If Debian asks to forward upstream

Use the Linux source tree to find maintainers:

```bash
cd /usr/src/linux-source-6.19
./scripts/get_maintainer.pl \
  -f drivers/media/pci/intel/ipu-bridge.c \
  -f drivers/media/i2c/ov01a1s.c
```

The likely upstream audience is the Linux media subsystem and the relevant
Intel IPU6 / OV01A1S maintainers. Send a plain-text email with the same report
and patch. Do not send screenshots as the primary evidence; logs and patch are
more useful.

If a Debian bug number exists first, include it in the upstream email:

```text
Debian bug: https://bugs.debian.org/<bug-number>
```

If an upstream thread or bug exists later, add it back to Debian with:

```bash
sudo apt install devscripts
bts forwarded <debian-bug-number> <upstream-url>
```

## Expected follow-up questions

Be prepared to answer:

```text
Does it reproduce with an official Debian kernel package?
Does a newer Debian unstable/experimental kernel fix it?
Does a vanilla upstream kernel still miss OVTI01AF?
Can you test this small patch?
Can you provide full dmesg and media-ctl output from a clean boot?
Is the Windows evidence from text INF/XML only, without proprietary blobs?
```

The strongest evidence you already have is that adding `OVTI01AF` locally makes
the sensor enumerate and raw capture work.

