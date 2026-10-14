# Webcam kernel report: Intel IPU6 + OV01A1S sensor with ACPI ID OVTI01AF

## Summary

Internal laptop webcam is connected through Intel IPU6 and uses an OmniVision
OV01A1S-compatible sensor exposed by ACPI as `OVTI01AF:00`.

On Debian with kernel `6.19.14+deb14-amd64`, the IPU6 controller and firmware
load, but the camera is not usable with the stock kernel until the sensor ID is
manually added to the IPU bridge and the OV01A1S sensor driver ACPI table.

The minimal kernel-side issue appears to be missing ACPI ID coverage:

- `drivers/media/pci/intel/ipu-bridge.c` has `OVTI01AS` but not `OVTI01AF`.
- The OV01A1S sensor driver also needs to match `OVTI01AF`.

After locally adding `OVTI01AF`, the media graph is created and raw capture from
the sensor works.

## Hardware and software context

- Machine class: Intel Tiger Lake / Intel Evo / Intel NUC-style laptop platform.
- Camera controller: Intel IPU6 at PCI `0000:00:05.0`.
- Media controller: `/dev/media0`, driver `intel-ipu6`.
- Sensor ACPI device: `OVTI01AF:00`.
- Sensor driver observed after local patch: `ov01a1s 4-0036`.
- Kernel tested: `6.19.14+deb14-amd64`.
- Distribution: Debian.

The camera is not a USB/UVC webcam. `lsusb` does not expose a webcam device.
It is a MIPI CSI-2 sensor behind Intel IPU6.

## Evidence from Linux

### IPU6 is present

`lspci` showed the IPU6 controller:

```text
00:05.0 Multimedia controller [0480]: Intel Corporation Tiger Lake IPU6 [8086:9a19]
```

### Kernel config has IPU6 and IPU bridge

```text
CONFIG_VIDEO_INTEL_IPU6=m
CONFIG_IPU_BRIDGE=m
```

The OV01A1S sensor module was available locally after adding the `OVTI01AF`
ACPI alias during testing.

### Initial failure mode

Before adding the `OVTI01AF` mapping to the bridge, the sensor module could be
loaded only after adding an alias, but probe was deferred because no complete
firmware-node graph was created for the sensor:

```text
ov01a1s i2c-OVTI01AF:00: failed to check hwcfg: -517
i2c i2c-OVTI01AF:00: deferred probe pending
```

The local kernel source had `OVTI01AS` in `ipu-bridge.c`, but no `OVTI01AF`:

```text
IPU_SENSOR_CONFIG("OVTI01AS", 1, 400000000),
```

Adding the equivalent entry for `OVTI01AF` allowed the IPU bridge to connect
the sensor.

### Working state after local patch

After adding `OVTI01AF` to the IPU bridge and the OV01A1S driver, the media
graph contains the sensor:

```text
entity 465: ov01a1s 4-0036 (1 pad, 1 link, 0 routes)
        device node name /dev/v4l-subdev8
        pad0: SOURCE
                [stream:0 fmt:SGRBG10_1X10/1288x800 field:none]
                -> "Intel IPU6 CSI2 5":0 [ENABLED,IMMUTABLE]
```

The connected CSI-2 receiver is:

```text
entity 307: Intel IPU6 CSI2 5
        pad0: SINK,MUST_CONNECT
                [stream:0 fmt:SGRBG10_1X10/1288x800 field:none]
                <- "ov01a1s 4-0036":0 [ENABLED,IMMUTABLE]
        pad1: SOURCE
                [stream:0 fmt:SGRBG10_1X10/1288x800 field:none]
                -> "Intel IPU6 ISYS Capture 40":0 [ENABLED]
```

`cam --list` then enumerates the camera:

```text
1: 'ov01a1s' (\_SB_.PC00.LNK0)
```

Raw capture works:

```text
cam -c 1 --capture=5 -s role=raw,width=1288,height=800 \
  --file=/home/css/dev/webcam/diagnostics/current/frames/raw-#.bin
```

The captured stream is raw Bayer/RGB-IR-like data:

```text
1288x800-SGRBG10/RAW
```

`v4l2-ctl -d /dev/video40 --get-fmt-video` reports:

```text
Format Video Capture:
        Width/Height      : 1288/800
        Pixel Format      : 'BA10' (10-bit Bayer GRGR/BGBG)
        Field             : None
        Bytes per Line    : 2624
        Size Image        : 2101824
        Colorspace        : Raw
```

## Evidence from the Windows driver package

The Windows driver package contains:

```text
ov01a1s.inf_amd64_7d82bb1f5e3fbb06/
```

The INF explicitly identifies the same ACPI ID:

```text
INF file for installing OV01A1S camera sensor (ACPI\OVTI01AF) driver
%ov01a1s.DeviceDesc%=ov01a1s_Device, ACPI\OVTI01AF
```

The Windows graph settings show that the sensor is RGB-IR, not a plain RGB
Bayer sensor:

```text
sensor_name="OV01A1S"
bayer_order="GRGB_IGIG_GBGR_IGIG"
sensor_type="RGB_IR"
```

The rotated profile contains:

```text
bayer_order="GIGI_RGBG_GIGI_BGRG"
sensor_type="RGB_IR"
```

The Windows graph uses a `1296x800` sensor mode, while the Linux raw capture
path exposes `1288x800`. That difference appears to be bridge/crop-related and
does not prevent raw capture after the ACPI mapping fix.

The Windows binaries/calibration blobs are not attached here; the relevant
information above is extracted from text `.inf` and `.xml` files.

## Minimal proposed kernel change

The local workaround that made the sensor enumerate was equivalent to:

```diff
diff --git a/drivers/media/pci/intel/ipu-bridge.c b/drivers/media/pci/intel/ipu-bridge.c
--- a/drivers/media/pci/intel/ipu-bridge.c
+++ b/drivers/media/pci/intel/ipu-bridge.c
@@
 	IPU_SENSOR_CONFIG("OVTI01A0", 1, 400000000),
 	IPU_SENSOR_CONFIG("OVTI01AS", 1, 400000000),
+	IPU_SENSOR_CONFIG("OVTI01AF", 1, 400000000),
 	IPU_SENSOR_CONFIG("OVTI02C1", 1, 400000000),
```

And the OV01A1S sensor driver needs the matching ACPI ID:

```diff
diff --git a/drivers/media/i2c/ov01a1s.c b/drivers/media/i2c/ov01a1s.c
--- a/drivers/media/i2c/ov01a1s.c
+++ b/drivers/media/i2c/ov01a1s.c
@@
 static const struct acpi_device_id ov01a1s_acpi_ids[] = {
 	{ "OVTI01AS" },
+	{ "OVTI01AF" },
 	{}
 };
```

## Remaining limitation after the kernel fix

The ACPI mapping fix is enough to make the sensor enumerate and raw capture
work. It does not provide good end-user image quality by itself.

The sensor is RGB-IR and still needs a proper ISP/libcamera pipeline:

- RGB-IR demosaic / IR subtraction
- auto exposure
- auto white balance
- color correction matrix
- gamma/tone mapping
- denoise
- lens shading or tuning data handling

With the current Linux userspace stack, `libcamera` falls back to simple/legacy
handling and emits warnings such as missing static properties and missing
sensor helper/tuning. A temporary userspace bridge can convert raw frames to a
v4l2loopback camera, but image quality remains inferior to Windows because the
full OEM ISP/tuning pipeline is not available.

## Requested outcome

Please consider adding `OVTI01AF` support for OV01A1S on Intel IPU6 platforms:

1. Add `OVTI01AF` to the OV01A1S sensor driver ACPI match table if missing.
2. Add `OVTI01AF` to the Intel IPU bridge sensor config with the same parameters
   as `OVTI01AS`: one CSI-2 lane and `400000000` Hz link frequency.

This should make the camera enumerate on affected machines without local kernel
module patching. Image quality/tuning can be treated as a separate follow-up
issue.

## Useful local artifacts

Local diagnostics collected in this repository:

```text
diagnostics/current/dmesg-after-ipu-bridge-crc32.txt
diagnostics/current/media-ctl-after-ipu-bridge-crc32.txt
diagnostics/current/cam-list-after-ipu-bridge-crc32.txt
diagnostics/current/cam-raw-capture-final.txt
diagnostics/current/v4l2-formats-video40.txt
```

Temporary userspace bridge used for experimentation:

```text
src/ipu6_ba10_to_loopback.c
```
