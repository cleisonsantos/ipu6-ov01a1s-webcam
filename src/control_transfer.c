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
    unsigned char data[2] = {0};
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

    if (libusb_kernel_driver_active(handle, 0) == 1) {
        fprintf(stderr, "note: kernel driver is active on interface 0\n");
        fprintf(stderr, "control transfers on endpoint zero may still work, but interface claims can fail later\n");
    }

    rc = libusb_control_transfer(
        handle,
        LIBUSB_ENDPOINT_IN | LIBUSB_REQUEST_TYPE_STANDARD | LIBUSB_RECIPIENT_DEVICE,
        LIBUSB_REQUEST_GET_STATUS,
        0,
        0,
        data,
        sizeof(data),
        1000
    );

    if (rc < 0) {
        fprintf(stderr, "control transfer failed: %s\n", libusb_error_name(rc));
        libusb_close(handle);
        libusb_exit(ctx);
        return EXIT_FAILURE;
    }

    printf("GET_STATUS returned %d bytes\n", rc);
    if (rc == 2) {
        uint16_t status = (uint16_t)data[0] | ((uint16_t)data[1] << 8);
        printf("device status: 0x%04x\n", status);
    } else {
        for (int i = 0; i < rc; ++i) {
            printf("data[%d] = 0x%02x\n", i, data[i]);
        }
    }

    libusb_close(handle);
    libusb_exit(ctx);
    return EXIT_SUCCESS;
}
