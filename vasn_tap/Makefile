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

# Compiler flags
CFLAGS := -Wall -Wextra -O2 -g -pthread
CFLAGS += -I$(INCLUDE_DIR) -I$(SRC_DIR)

# Linker flags
LDFLAGS := -lbpf -lelf -lz -lpthread

# BPF compiler flags
BPF_CFLAGS := -g -O2 -target bpf
BPF_CFLAGS += -D__TARGET_ARCH_x86
BPF_CFLAGS += -I$(INCLUDE_DIR) -I$(EBPF_DIR)

# Source files
SRCS := $(SRC_DIR)/main.c \
        $(SRC_DIR)/tap.c \
        $(SRC_DIR)/worker.c \
        $(SRC_DIR)/output.c

# Object files
OBJS := $(patsubst $(SRC_DIR)/%.c,$(BUILD_DIR)/%.o,$(SRCS))

# BPF source
BPF_SRC := $(EBPF_DIR)/tc_clone.bpf.c

# vmlinux.h path
VMLINUX_H := $(EBPF_DIR)/vmlinux.h

.PHONY: all clean install vmlinux

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
$(BUILD_DIR)/%.o: $(SRC_DIR)/%.c $(SRC_DIR)/tap.h $(SRC_DIR)/worker.h $(SRC_DIR)/output.h $(INCLUDE_DIR)/common.h
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

# Help
help:
	@echo "vasn_tap Build System"
	@echo ""
	@echo "Targets:"
	@echo "  all      - Build everything (default)"
	@echo "  clean    - Remove build artifacts"
	@echo "  vmlinux  - Generate vmlinux.h only"
	@echo "  install  - Install to /usr/local (requires root)"
	@echo "  help     - Show this help"
	@echo ""
	@echo "Requirements:"
	@echo "  - Linux kernel >= 5.10 with BTF support"
	@echo "  - clang/llvm >= 11"
	@echo "  - libbpf-dev, libelf-dev, zlib1g-dev"
	@echo "  - bpftool"
