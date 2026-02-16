# vasn_tap - High Performance eBPF Packet Tap
# Makefile for building eBPF programs and userspace application

# Compiler settings
CC := gcc
CLANG := clang
LLC := llc
BPFTOOL := bpftool

# Directories
SRC_DIR := src
EBPF_DIR := $(SRC_DIR)/ebpf
INCLUDE_DIR := include
BUILD_DIR := build

# Target
TARGET := vasn_tap
BPF_OBJ := tc_clone.bpf.o

# Version / build info (for main.c; no spaces in value to keep -D one token)
GIT_COMMIT := $(shell git rev-parse --short HEAD 2>/dev/null || echo "unknown")
BUILD_DATETIME := $(shell date -u +"%Y-%m-%dT%H:%M:%SZ")

# Compiler flags
CFLAGS := -Wall -Wextra -O2 -g -pthread
CFLAGS += -I$(INCLUDE_DIR) -I$(SRC_DIR)
CFLAGS += -DVASN_TAP_GIT_COMMIT=\"$(GIT_COMMIT)\"
CFLAGS += -DVASN_TAP_BUILD_DATETIME=\"$(BUILD_DATETIME)\"

# Linker flags
LDFLAGS := -lbpf -lelf -lz -lpthread -lyaml

# BPF compiler flags
BPF_CFLAGS := -g -O2 -target bpf
BPF_CFLAGS += -D__TARGET_ARCH_x86
BPF_CFLAGS += -I$(INCLUDE_DIR) -I$(EBPF_DIR)

# Source files (output.c only used by unit test test_output)
SRCS := $(SRC_DIR)/main.c \
        $(SRC_DIR)/tap.c \
        $(SRC_DIR)/worker.c \
        $(SRC_DIR)/tx_ring.c \
        $(SRC_DIR)/afpacket.c \
        $(SRC_DIR)/cli.c \
        $(SRC_DIR)/config.c \
        $(SRC_DIR)/filter.c \
        $(SRC_DIR)/tunnel.c

# Test directories
TEST_UNIT_DIR := tests/unit
TEST_INTEG_DIR := tests/integration

# Test libraries
TEST_LDFLAGS := -lcmocka

# Object files used by tests (everything except main.o, tap.o; output.o only for test_output)
TEST_OBJS := $(BUILD_DIR)/afpacket.o $(BUILD_DIR)/worker.o $(BUILD_DIR)/tx_ring.o $(BUILD_DIR)/cli.o $(BUILD_DIR)/config.o $(BUILD_DIR)/filter.o $(BUILD_DIR)/tunnel.o

# Object files
OBJS := $(patsubst $(SRC_DIR)/%.c,$(BUILD_DIR)/%.o,$(SRCS))

# BPF source
BPF_SRC := $(EBPF_DIR)/tc_clone.bpf.c

# vmlinux.h path
VMLINUX_H := $(EBPF_DIR)/vmlinux.h

.PHONY: all clean install vmlinux test test-basic test-filter test-tunnel test-all help

all: $(BUILD_DIR) $(VMLINUX_H) $(BPF_OBJ) $(TARGET)

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

# Generate vmlinux.h from running kernel's BTF
$(VMLINUX_H):
	@echo "Generating vmlinux.h from kernel BTF..."
	@if [ -f /sys/kernel/btf/vmlinux ]; then \
		$(BPFTOOL) btf dump file /sys/kernel/btf/vmlinux format c > $@; \
	else \
		echo "Error: /sys/kernel/btf/vmlinux not found. Kernel BTF support required."; \
		exit 1; \
	fi

# Compile BPF program
$(BPF_OBJ): $(BPF_SRC) $(VMLINUX_H) $(EBPF_DIR)/tc_clone.h
	@echo "Compiling eBPF program..."
	$(CLANG) $(BPF_CFLAGS) -c $< -o $@

# Compile userspace objects
$(BUILD_DIR)/%.o: $(SRC_DIR)/%.c $(SRC_DIR)/tap.h $(SRC_DIR)/worker.h $(SRC_DIR)/output.h $(SRC_DIR)/tx_ring.h $(SRC_DIR)/afpacket.h $(SRC_DIR)/cli.h $(SRC_DIR)/config.h $(SRC_DIR)/filter.h $(SRC_DIR)/tunnel.h $(INCLUDE_DIR)/common.h
	@echo "Compiling $<..."
	$(CC) $(CFLAGS) -c $< -o $@

# Link userspace application
$(TARGET): $(OBJS)
	@echo "Linking $(TARGET)..."
	$(CC) $(CFLAGS) -o $@ $^ $(LDFLAGS)
	@echo "Build complete: $(TARGET)"

# Clean build artifacts
clean:
	rm -rf $(BUILD_DIR)
	rm -f $(TARGET)
	rm -f $(BPF_OBJ)
	rm -f $(VMLINUX_H)

# Install (requires root)
install: $(TARGET) $(BPF_OBJ)
	@echo "Installing $(TARGET)..."
	install -m 755 $(TARGET) /usr/local/bin/
	install -m 644 $(BPF_OBJ) /usr/local/share/vasn_tap/
	@echo "Installation complete"

# Generate vmlinux.h only
vmlinux: $(VMLINUX_H)
	@echo "vmlinux.h generated at $(VMLINUX_H)"

# ---- Unit Tests ----

$(BUILD_DIR)/test_stats: $(TEST_UNIT_DIR)/test_stats.c $(TEST_OBJS)
	@echo "Building test_stats..."
	$(CC) $(CFLAGS) -o $@ $< $(TEST_OBJS) $(LDFLAGS) $(TEST_LDFLAGS)

$(BUILD_DIR)/test_config: $(TEST_UNIT_DIR)/test_config.c $(TEST_OBJS)
	@echo "Building test_config..."
	$(CC) $(CFLAGS) -o $@ $< $(TEST_OBJS) $(LDFLAGS) $(TEST_LDFLAGS)

$(BUILD_DIR)/test_cli: $(TEST_UNIT_DIR)/test_cli.c $(BUILD_DIR)/cli.o
	@echo "Building test_cli..."
	$(CC) $(CFLAGS) -o $@ $< $(BUILD_DIR)/cli.o $(TEST_LDFLAGS)

$(BUILD_DIR)/test_output: $(TEST_UNIT_DIR)/test_output.c $(BUILD_DIR)/output.o
	@echo "Building test_output..."
	$(CC) $(CFLAGS) -o $@ $< $(BUILD_DIR)/output.o $(TEST_LDFLAGS)

$(BUILD_DIR)/test_filter: $(TEST_UNIT_DIR)/test_filter.c $(BUILD_DIR)/config.o $(BUILD_DIR)/filter.o
	@echo "Building test_filter..."
	$(CC) $(CFLAGS) -I$(SRC_DIR) -o $@ $< $(BUILD_DIR)/config.o $(BUILD_DIR)/filter.o $(TEST_LDFLAGS) -lyaml

$(BUILD_DIR)/test_config_filter: $(TEST_UNIT_DIR)/test_config_filter.c $(BUILD_DIR)/config.o
	@echo "Building test_config_filter..."
	$(CC) $(CFLAGS) -I$(SRC_DIR) -o $@ $< $(BUILD_DIR)/config.o $(TEST_LDFLAGS) -lyaml

# Run all unit tests (no root required)
test: $(BUILD_DIR)/test_stats $(BUILD_DIR)/test_config $(BUILD_DIR)/test_cli $(BUILD_DIR)/test_output $(BUILD_DIR)/test_filter $(BUILD_DIR)/test_config_filter
	@echo ""
	@echo "=== Running Unit Tests ==="
	@echo ""
	@PASS=0; FAIL=0; \
	for t in $(BUILD_DIR)/test_stats $(BUILD_DIR)/test_config $(BUILD_DIR)/test_cli $(BUILD_DIR)/test_output $(BUILD_DIR)/test_filter $(BUILD_DIR)/test_config_filter; do \
		echo "--- $$t ---"; \
		if $$t; then PASS=$$((PASS+1)); else FAIL=$$((FAIL+1)); fi; \
		echo ""; \
	done; \
	echo "=== Unit Tests: $$PASS passed, $$FAIL failed ==="; \
	[ $$FAIL -eq 0 ]

# Integration tests (require root; each generates its own HTML report)
test-basic: $(TARGET)
	@echo ""
	@echo "=== Basic Integration Tests (8 cases) ==="
	@echo "(requires root)"
	@echo ""
	sudo $(TEST_INTEG_DIR)/run_integ.sh basic

test-filter: $(TARGET)
	@echo ""
	@echo "=== Filter Integration Tests (10 cases) ==="
	@echo "(requires root)"
	@echo ""
	sudo $(TEST_INTEG_DIR)/run_integ.sh filter

test-tunnel: $(TARGET)
	@echo ""
	@echo "=== Tunnel Integration Tests (2 cases: GRE, VXLAN) ==="
	@echo "(requires root)"
	@echo ""
	sudo $(TEST_INTEG_DIR)/run_integ.sh tunnel

test-all: $(TARGET)
	@echo ""
	@echo "=== All Integration Tests (20 cases: basic + filter + tunnel) ==="
	@echo "(requires root)"
	@echo ""
	sudo $(TEST_INTEG_DIR)/run_integ.sh all

# Help
help:
	@echo "vasn_tap Build System"
	@echo ""
	@echo "Targets:"
	@echo "  all         - Build everything (default)"
	@echo "  clean       - Remove build artifacts"
	@echo "  test        - Run unit tests (no root needed)"
	@echo "  test-basic  - Run basic integration tests, 8 cases (needs root, reports in tests/integration/reports/)"
	@echo "  test-filter  - Run filter integration tests, 10 cases (needs root, reports in tests/integration/reports/)"
	@echo "  test-tunnel  - Run tunnel integration tests, 2 cases GRE+VXLAN (needs root, reports in tests/integration/reports/)"
	@echo "  test-all     - Run all integration tests, 20 cases (needs root, reports in tests/integration/reports/)"
	@echo "  vmlinux     - Generate vmlinux.h only"
	@echo "  install     - Install to /usr/local (requires root)"
	@echo "  help        - Show this help"
	@echo ""
	@echo "Requirements:"
	@echo "  - Linux kernel >= 5.10 with BTF support"
	@echo "  - clang/llvm >= 11"
	@echo "  - libbpf-dev, libelf-dev, zlib1g-dev"
	@echo "  - bpftool"
	@echo "  - libcmocka-dev (for unit tests)"
