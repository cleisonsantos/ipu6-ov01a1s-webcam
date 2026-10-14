#include <libusb-1.0/libusb.h>

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

static uint16_t parse_u16(const char *text) {
    char *end = NULL;
    unsigned long value = strtoul(text, &end, 0);

    if (text == end || *end != '\0' || value > 0xFFFFu) {
        fprintf(stderr, "invalid 16-bit value: %s\n", text);
        exit(EXIT_FAILURE);
    }

    return (uint16_t)value;
}

int main(int argc, char **argv) {
    libusb_context *ctx = NULL;
    libusb_device_handle *handle = NULL;
    struct libusb_device_descriptor desc;
    int rc;

    if (argc != 3) {
        fprintf(stderr, "usage: %s <vid> <pid>\n", argv[0]);
        return EXIT_FAILURE;
    }

    uint16_t vid = parse_u16(argv[1]);
    uint16_t pid = parse_u16(argv[2]);

    rc = libusb_init(&ctx);
    if (rc != 0) {
        fprintf(stderr, "libusb_init failed: %s\n", libusb_error_name(rc));
        return EXIT_FAILURE;
    }

    handle = libusb_open_device_with_vid_pid(ctx, vid, pid);
    if (!handle) {
        fprintf(stderr, "device %04x:%04x not found or could not be opened\n", vid, pid);
        libusb_exit(ctx);
        return EXIT_FAILURE;
    }

    libusb_device *dev = libusb_get_device(handle);
    rc = libusb_get_device_descriptor(dev, &desc);
    if (rc != 0) {
        fprintf(stderr, "libusb_get_device_descriptor failed: %s\n", libusb_error_name(rc));
        libusb_close(handle);
        libusb_exit(ctx);
        return EXIT_FAILURE;
    }

    printf("opened device %04x:%04x\n", vid, pid);
    printf("bcdUSB:          0x%04x\n", desc.bcdUSB);
    printf("device class:    0x%02x\n", desc.bDeviceClass);
    printf("device subclass: 0x%02x\n", desc.bDeviceSubClass);
    printf("device protocol: 0x%02x\n", desc.bDeviceProtocol);
    printf("max packet size: %u\n", desc.bMaxPacketSize0);
    printf("num configs:     %u\n", desc.bNumConfigurations);

    libusb_close(handle);
    libusb_exit(ctx);
    return EXIT_SUCCESS;
}
