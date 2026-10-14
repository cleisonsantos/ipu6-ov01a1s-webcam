# V4L2 Driver Roadmap

This project starts in user space and leaves room for a future kernel driver.

## Phase 1: User-space reconnaissance

- enumerate the USB device
- inspect descriptors and interface layout
- identify control, bulk, interrupt, or isochronous endpoints
- test safe read-oriented control transfers

## Phase 2: Protocol sketching

- map initialization sequence
- identify streaming start and stop commands
- determine frame format and transport framing
- log timing, altsetting, and bandwidth requirements

## Phase 3: User-space bridge

- decode payloads in user space
- convert to a standard format such as YUYV or MJPEG
- write frames into `v4l2loopback`

## Phase 4: Kernel preparation

- define device state structure
- model USB transport paths
- map controls to V4L2 control handlers
- expose one video node with capture capabilities

## Phase 5: Driver implementation

- probe and disconnect paths
- USB URB lifecycle management
- streaming state machine
- V4L2 ioctl operations
- buffer management and format negotiation

## Kernel Areas To Study

- `drivers/media/usb/uvc/`
- `drivers/media/usb/gspca/`
- `Documentation/driver-api/media/`
- `Documentation/userspace-api/media/v4l/`
