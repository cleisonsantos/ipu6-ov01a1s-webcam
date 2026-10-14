# Run the IPU6 webcam workaround

This is the practical path when the camera must work in GNOME Camera, OBS, or a
meeting app.

## Color via hardware ISP (recommended)

This uses Intel's `ipu6-camera-hal` + `icamerasrc` (hardware ISP with AIQ
tuning, auto exposure and auto white balance). Setup (once):

```bash
sudo bash tools/setup_ipu6_camera_deps.sh      # build deps + ipu6-camera-bins
sudo bash tools/setup_ipu6_isp_permissions.sh  # /dev/ipu-psys0 + /run/camera
```

Then run the pipeline that publishes the ISP output to `/dev/video90`:

```bash
tools/start_ipu6_isp_webcam.sh
```

If the image is upside down the script already applies `videoflip
method=rotate-180`; disable it with `FLIP=no tools/start_ipu6_isp_webcam.sh`.
The HAL config used is the adjusted copy in `ipu6-hal-config/` (sensor profile
points at `ov01a1s-uf-5`, the CSI2 port of this board).

## Stable meeting mode (monochrome, userspace bridge)

This mode intentionally outputs monochrome YUYV. It avoids the bad RGB-IR color
reconstruction that causes green/magenta images.

```bash
cd ~/dev/webcam
chmod +x tools/start_ipu6_webcam_meeting.sh
tools/start_ipu6_webcam_meeting.sh
```

Then open the app and select:

```text
IPU6 Virtual Camera
/dev/video90
```

If the image is upside down, force rotation:

```bash
ROTATE=yes tools/start_ipu6_webcam_meeting.sh
```

If the app rotates it twice and it becomes upside down, disable rotation:

```bash
ROTATE=no tools/start_ipu6_webcam_meeting.sh
```

If the image is too dark:

```bash
TARGET_LUMA=115 CONTRAST=1050 BRIGHTNESS=-4 tools/start_ipu6_webcam_meeting.sh
```

If the image is too bright/noisy:

```bash
TARGET_LUMA=75 CONTRAST=850 BRIGHTNESS=-20 tools/start_ipu6_webcam_meeting.sh
```

## Color mode remains experimental

The sensor is RGB-IR. Without a proper ISP/libcamera tuning pipeline, color is
not reliable. Use the monochrome mode when you need a stable camera.

Try the built-in color mode:

```bash
COLOR=yes tools/start_ipu6_webcam_meeting.sh
```

If it is too green, reduce IR subtraction and saturation:

```bash
COLOR=yes IR_SUBTRACT=0 SATURATION=450 U_GAIN=650 V_GAIN=1250 tools/start_ipu6_webcam_meeting.sh
```

If it is nearly monochrome, increase chroma:

```bash
COLOR=yes IR_SUBTRACT=0 SATURATION=900 U_GAIN=850 V_GAIN=1400 tools/start_ipu6_webcam_meeting.sh
```

## If the bridge fails to start

Close GNOME Camera, OBS, browser tabs, and meeting apps. Then check who is using
the devices:

```bash
fuser -v /dev/video40 /dev/video90 /dev/media0
```

If WirePlumber holds `/dev/video40`, the safest workaround is to close camera
apps and retry. Stopping WirePlumber can affect desktop audio, so this script
does not do it automatically.
