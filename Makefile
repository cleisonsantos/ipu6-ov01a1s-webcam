CC ?= gcc
CFLAGS ?= -std=c11 -Wall -Wextra -Wpedantic -O2
CPPFLAGS ?=
LDFLAGS ?=
LDLIBS ?= -lusb-1.0

SRC_DIR := src
BUILD_DIR := build
BIN_DIR := $(BUILD_DIR)/bin

TARGETS := usb_open control_transfer ipu6_ba10_to_loopback

.PHONY: all clean dirs help

all: dirs $(TARGETS:%=$(BIN_DIR)/%)

dirs:
	mkdir -p $(BIN_DIR)

$(BIN_DIR)/usb_open: $(SRC_DIR)/usb_open.c | dirs
	$(CC) $(CPPFLAGS) $(CFLAGS) $< -o $@ $(LDFLAGS) $(LDLIBS)

$(BIN_DIR)/control_transfer: $(SRC_DIR)/control_transfer.c | dirs
	$(CC) $(CPPFLAGS) $(CFLAGS) $< -o $@ $(LDFLAGS) $(LDLIBS)

$(BIN_DIR)/ipu6_ba10_to_loopback: $(SRC_DIR)/ipu6_ba10_to_loopback.c | dirs
	$(CC) $(CPPFLAGS) $(CFLAGS) $< -o $@ $(LDFLAGS) -lm

clean:
	rm -rf $(BUILD_DIR)

help:
	@echo "Targets:"
	@echo "  all      Build all examples"
	@echo "  clean    Remove build artifacts"
	@echo "  help     Show this message"
