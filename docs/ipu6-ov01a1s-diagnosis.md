# IPU6 / OV01A1S Diagnosis

Current machine:

- Platform: Intel Tiger Lake IPU6
- Media controller: `/dev/media0`
- Sensor ACPI ID: `OVTI01AF:00`
- Likely sensor family: OmniVision OV01A1S

## Confirmed Working

The IPU6 controller loads and authenticates firmware after a cold boot:

```text
intel-ipu6 0000:00:05.0: Sending BOOT_LOAD to CSE
intel-ipu6 0000:00:05.0: Sending AUTHENTICATE_RUN to CSE
intel-ipu6 0000:00:05.0: CSE authenticate_run done
```

The kernel has the IPU6 controller pieces enabled:

```text
CONFIG_VIDEO_INTEL_IPU6=m
CONFIG_IPU_BRIDGE=m
```

## Current Blocker

`libcamera` does not find a usable camera:

```text
No sensor found for /dev/media0
Available cameras:
```

The media graph exposes IPU6 ISYS and CSI2 entities, but no upstream camera sensor entity.

The kernel config contains:

```text
CONFIG_VIDEO_OV01A10=m
```

But it does not contain:

```text
CONFIG_VIDEO_OV01A1S=m
```

There is also no `ov01a1s` module under `/lib/modules/$(uname -r)`.

## Interpretation

This is not a USB webcam problem and not a `libusb` target.

The camera is a MIPI/CSI2 sensor behind Intel IPU6. The controller is present, but the sensor driver/binding for `OVTI01AF` is missing from the running kernel stack. Until the sensor driver binds, `media-ctl` will not show a complete graph and `cam --list` will not enumerate a camera.

## Next Technical Paths

1. Use a kernel that includes OV01A1S sensor support for `OVTI01AF`.
2. Port/build the OV01A1S sensor driver against the current Debian kernel.
3. Use Intel's IPU6 driver tree as a reference for the sensor driver and required config.
4. After the sensor binds, re-run:

```bash
media-ctl -p -d /dev/media0
cam --list
```

Expected improvement:

- a sensor entity appears upstream of one `Intel IPU6 CSI2 N` subdev
- `cam --list` shows at least one available camera

## References

- Intel IPU6 drivers: https://github.com/intel/ipu6-drivers
- OV01A product family: https://www.ovt.com/products/ov01a/
- Debian bug mentioning `CONFIG_VIDEO_OV01A1S`: https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=1087004
