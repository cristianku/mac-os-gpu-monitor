APP := gpu-monitor
SOURCE := Sources/mac-gpu-monitor/main.swift
BUILD_DIR := build

.PHONY: all build install clean

all: build

build:
	mkdir -p $(BUILD_DIR)
	swiftc -O -framework IOKit -framework Foundation $(SOURCE) -o $(BUILD_DIR)/$(APP)

install: build
	install -m 755 $(BUILD_DIR)/$(APP) /usr/local/bin/$(APP)

clean:
	rm -rf $(BUILD_DIR)
