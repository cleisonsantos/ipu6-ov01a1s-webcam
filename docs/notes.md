# Reverse Engineering Notes

Use this file to record:

- webcam VID/PID and revision
- USB descriptor observations
- interface numbers and altsettings
- endpoint types and packet sizes
- control request experiments
- usbmon or Wireshark capture notes

Suggested workflow:

1. Save `lsusb -d <vid>:<pid> -v` output
2. Record `dmesg` messages from plug-in time
3. Compare behavior with `uvcvideo`
4. Document each control request before sending write operations
