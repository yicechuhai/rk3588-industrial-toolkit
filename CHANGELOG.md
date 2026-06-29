# Changelog

## v1.0.0 (2026-06-29) — Initial Release

### 🚀 Core Modules

- **Zero-Copy Inference Engine** (`deploy/engine/`) — C++17 engine with RKNN API, DMA-BUF zero-copy, multi-NPU core scheduling, RGA hardware acceleration pipeline. Supports YOLOv5/v8/X with automatic NMS post-processing.
- **Modbus TCP Server** (`deploy/protocol/modbus/`) — Multi-client concurrent server based on libmodbus, YAML-driven register mapping, 20 detection slots × 6 registers each.
- **OPC UA Server** (`deploy/protocol/opcua/`) — Full information model with 20 detection slots, open62541-based, anonymous + username/password authentication.
- **Python Bindings** (`deploy/engine/python/`) — pybind11 wrapper with NumPy zero-copy I/O, Context Manager support, `pip install` and cmake dual build.

### ⚡ Real-Time Enhancement

- **PREEMPT_RT Auto-Build** (`deploy/realtime/build_rt_kernel.sh`) — 775-line script with 22 functions: auto-detect BSP kernel, match RT patch from version matrix, download + patch + configure + build + package as .deb.
- **CPU Isolation & IRQ Tuning** (`deploy/realtime/isolate_cpu.sh`) — One-click isolcpus + IRQ affinity + real-time scheduling limits + cyclictest benchmarking.
- **BSP ↔ RT Patch Matrix** (`deploy/realtime/version_matrix.yaml` / `.csv`) — 7 BSP kernel versions mapped to corresponding PREEMPT_RT patches.

### 🐳 Deployment

- **Docker Containerization** (`deploy/docker/`) — ARM64 Dockerfile + x86_64 cross-compile Dockerfile + docker-compose (inference + modbus + opcua services) + entrypoint script.
- **Offline Deployment Pack** (`deploy_scripts/offline_pack/build_offline.sh`) — Bundle .debs + .whls + project files into single tar.gz for air-gapped installation.
- **TUI Config Wizard** (`deploy_scripts/oneclick/web_config.sh`) — 6-step whiptail/dialog guided configuration, auto-generates engine.yaml.
- **Enhanced Installer** (`install.sh`) — 3 preset modes (`--full` / `--minimal` / `--ai-only`), interactive menu, install logging, post-install verification.

### 🔧 Drivers & Diagnostics

- **NPU Driver Management** (`patches/npu_driver/`) — Version detection + compatibility matrix check + automatic upgrade with rollback.
- **Performance Benchmarking** (`tools/benchmark/`) — CPU/NPU/RGA throughput and latency benchmarks.
- **System Diagnostics** (`tools/diagnose/`) — One-click fault diagnosis with HTML report.

### 🧪 Testing

- **45-Test Suite** (`tests/`) — Unit tests for Engine API, Modbus address parsing, OPC UA node model, integration tests for end-to-end pipeline latency and data consistency.
- **pytest Configuration** — pytest.ini with markers: `unit`, `integration`, `slow`, `hardware`.

### 📦 Supported Hardware

| Board | RAM | Storage | Status |
|-------|-----|---------|--------|
| NanoPC T6 | 8 GB LPDDR4x | 64 GB eMMC | ✅ Primary dev board |
| 鲁班猫 8 (LubanCat 8) | 8 GB LPDDR5 | 128 GB eMMC | ✅ Primary dev board |
| Orange Pi 5 Max | 8 GB+ | — | ✅ Verified |
| Radxa Rock 5B | 8 GB+ | — | ✅ Verified |
| 飞凌 OK3588-C | 4 GB+ | — | ✅ Compatible |
| 触觉智能 IDO-SOM3588 | — | — | ✅ Compatible |
| 东胜 DSOM-3588 | — | — | ✅ Compatible |

### 📊 Performance Targets

| Metric | Target | Condition |
|--------|--------|-----------|
| Interrupt latency (idle) | < 20 μs | PREEMPT_RT + cyclictest |
| Interrupt latency (loaded) | < 50 μs | stress-ng + iperf3 + NPU |
| YOLOv5s NPU inference | 54+ FPS | 640×640 INT8, 3 NPU cores |
| Video pipeline CPU usage | < 15% | RGA zero-copy mode |
| One-click deploy time | < 5 min | git clone → YOLO running |