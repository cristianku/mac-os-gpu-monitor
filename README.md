# mac-os-gpu-monitor

A lightweight `nvidia-smi`-style GPU monitor for macOS.

It reads GPU telemetry directly from the macOS I/O Registry (`IOAccelerator` / `PerformanceStatistics`) using a small native Swift binary. No Python, Homebrew, or third-party runtime is required.

Designed especially for AMD GPUs on Intel Macs / Hackintosh systems, while also exposing whatever telemetry the active macOS graphics driver publishes.

## Features

- GPU utilization
- VRAM used / total
- GPU temperature when exposed by the driver
- GPU core and memory clocks when exposed by the driver
- GPU power when exposed by the driver
- `nvidia-smi`-style terminal table
- JSON output for scripts
- continuous watch mode
- raw driver-statistics mode for discovering vendor-specific counters
- native Swift + IOKit implementation

> macOS does not expose a single stable public API equivalent to NVML. The exact counters available depend on the GPU, macOS version, and graphics driver. Missing metrics are shown as `N/A`.

## Install

Clone the repository and run:

```bash
git clone git@github.com:cristianku/mac-os-gpu-monitor.git
cd mac-os-gpu-monitor
bash install.sh
```

The installer builds the Swift source using Apple's Command Line Tools and installs:

```
/usr/local/bin/gpu-monitor
```

If `swiftc` is missing, install Apple's Command Line Tools:

```bash
xcode-select --install
```

## Usage

One-shot status:

```bash
gpu-monitor
```

Refresh every second:

```bash
gpu-monitor --watch
```

Refresh every 2 seconds:

```bash
gpu-monitor --watch 2
```

JSON:

```bash
gpu-monitor --json
```

Show all raw counters published by the GPU driver:

```bash
gpu-monitor --raw
```

Raw mode is particularly useful on Hackintosh/AMD systems because Apple/AMD driver versions may use different names for the same telemetry counters.

## Example

```text
mac-gpu-monitor 0.1.0   macOS 15.x
+--------------------------------------------------------------------------------+
| GPU  Name                         Util      VRAM             Temp     Power      |
|--------------------------------------------------------------------------------|
|  0   AMD Radeon RX 6800 XT        37.0%     4.8 / 16.0 GB    54 C     N/A        |
+--------------------------------------------------------------------------------+
```

## Build manually

```bash
make
./build/gpu-monitor
```

## Uninstall

```bash
sudo rm -f /usr/local/bin/gpu-monitor
```

## Technical notes

The monitor enumerates `IOAccelerator` services with IOKit and reads the `PerformanceStatistics` dictionary exported by the active graphics driver.

This is intentionally different from tools that scrape `powermetrics`:

- it does not require root privileges for normal operation;
- it can expose AMD-specific counters present in IOKit;
- it avoids parsing human-oriented command output.

Use `gpu-monitor --raw` first if a metric displays `N/A`. The raw output tells us the exact key names your Radeon driver exposes, which can then be mapped cleanly.

## License

MIT
